class ActiveRecord::Base
  module Mysql2PCExtensions
    extend ActiveSupport::Concern

    def begin_db_transaction
      @transaction_prepared = false
      execute("XA BEGIN '#{@current_xid}'")
    end

    def commit_db_transaction
      if @transaction_prepared
        commit_prepared_db_transaction(@current_xid)
      else
        execute("XA END '#{@current_xid}'")
        execute("XA COMMIT '#{@current_xid}' ONE PHASE")
      end
    end

    def rollback_db_transaction
      execute("XA END '#{@current_xid}'") unless @transaction_prepared
      rollback_prepared_db_transaction(@current_xid)
    end

    def prepare_db_transaction
      @transaction_prepared = true
      execute("XA END '#{@current_xid}'")
      execute("XA PREPARE '#{@current_xid}'")
    end

    def commit_prepared_db_transaction(xid)
      execute("XA COMMIT '#{xid}'")
    rescue Exception => e
      raise unless e.message =~ /Unknown XID/
    end

    def rollback_prepared_db_transaction(xid)
      execute("XA ROLLBACK '#{xid}'")
    rescue Exception => e
      raise unless e.message =~ /Unknown XID/
    end

    def supports_returning_statments?
      false
    end

    included do
      Promiscuous::Publisher::Operation::Base.register_recovery_mechanism do
        connection = ActiveRecord::Base.connection
        connection.exec_query("XA RECOVER", "Promiscuous Recovery").each do |tx|
          ActiveRecord::Base::PromiscuousTransaction.recover_transaction(connection, tx['data'])
        end
      end
    end
  end

  module Oracle2PCExtensions
    def execute_proc(procedure, expected_return_value)
      execute("DECLARE ret NUMBER:=0; BEGIN ret:=#{procedure}; IF ret != #{expected_return_value} THEN RAISE_APPLICATION_ERROR(-20000, ret); END IF; END;")
    end

    def begin_db_transaction
      @transaction_prepared = false
      execute_proc("DBMS_XA.XA_START(dbms_xa_xid('#{@current_xid}'), DBMS_XA.TMNOFLAGS)", "DBMS_XA.XA_OK")
    end

    def commit_db_transaction
      if @transaction_prepared
        commit_prepared_db_transaction(@current_xid)
      else
        execute_proc("DBMS_XA.XA_END(dbms_xa_xid('#{@current_xid}'), DBMS_XA.TMSUCCESS)", "DBMS_XA.XA_OK")
        execute_proc("DBMS_XA.XA_COMMIT(dbms_xa_xid('#{@current_xid}'), TRUE)", "DBMS_XA.XA_OK")
      end
    end

    def rollback_db_transaction
      execute_proc("DBMS_XA.XA_END(dbms_xa_xid('#{@current_xid}'), DBMS_XA.TMSUCCESS)", "DBMS_XA.XA_OK") unless @transaction_prepared
      rollback_prepared_db_transaction(@current_xid)
    end

    def prepare_db_transaction
      @transaction_prepared = true
      execute_proc("DBMS_XA.XA_END(dbms_xa_xid('#{@current_xid}'), DBMS_XA.TMSUCCESS)", "DBMS_XA.XA_OK")
      execute_proc("DBMS_XA.XA_PREPARE(dbms_xa_xid('#{@current_xid}'))", "DBMS_XA.XA_OK")
    end

    def commit_prepared_db_transaction(xid)
      execute_proc("DBMS_XA.XA_COMMIT(dbms_xa_xid('#{xid}'), FALSE)", "DBMS_XA.XA_OK")
    rescue Exception => e
      raise unless e.message =~ /Unknown XID/
    end

    def rollback_prepared_db_transaction(xid)
      execute_proc("DBMS_XA.XA_ROLLBACK(dbms_xa_xid('#{xid}'))", "DBMS_XA.XA_OK")
    rescue Exception => e
      raise unless e.message =~ /Unknown XID/
    end

    def supports_returning_statments?
      false
    end
  end

  module PostgresSQL2PCExtensions
    extend ActiveSupport::Concern

    def prepare_db_transaction
      @transaction_prepared = true
      execute("PREPARE TRANSACTION '#{@current_xid}'")
    end

    def commit_prepared_db_transaction(xid)
      execute("COMMIT PREPARED '#{xid}'")
    rescue Exception => e
      raise unless e.message =~ /^PG::UndefinedObject/
    end

    def rollback_prepared_db_transaction(xid)
      execute("ROLLBACK PREPARED '#{xid}'")
    rescue Exception => e
      raise unless e.message =~ /^PG::UndefinedObject/
    end

    def supports_returning_statments?
      true
    end

    included do
      # We want to make sure that we never block the database by having
      # uncommitted transactions.
      Promiscuous::Publisher::Operation::Base.register_recovery_mechanism do
        connection = ActiveRecord::Base.connection
        db_name = connection.current_database

        # We wait twice the time of expiration, to allow a better recovery scenario.
        expire_duration = 2 * Promiscuous::Publisher::Operation::Base.lock_options[:expire]

        q = "SELECT gid FROM pg_prepared_xacts " +
            "WHERE database = '#{db_name}' " +
            "AND prepared < current_timestamp + #{expire_duration} * interval '1 second'"

        connection.exec_query(q, "Promiscuous Recovery").each do |tx|
          ActiveRecord::Base::PromiscuousTransaction.recover_transaction(connection, tx['gid'])
        end
      end
    end
  end

  class << self
    alias_method :connection_without_promiscuous, :connection

    def connection
      connection_without_promiscuous.tap do |connection|
        unless defined?(connection.promiscuous_hook)
          connection.class.class_eval do
            def promiscuous_hook; end

            case self.name
            when "ActiveRecord::ConnectionAdapters::PostgreSQLAdapter"
              include ActiveRecord::Base::PostgresSQL2PCExtensions
            when "ActiveRecord::ConnectionAdapters::Mysql2Adapter"
              include ActiveRecord::Base::Mysql2PCExtensions
            when "ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter"
              include ActiveRecord::Base::Oracle2PCExtensions
            end

            alias_method :begin_db_transaction_without_promiscuous,    :begin_db_transaction
            alias_method :create_savepoint_without_promiscuous,        :create_savepoint
            alias_method :rollback_db_transaction_without_promiscuous, :rollback_db_transaction
            alias_method :rollback_to_savepoint_without_promiscuous,   :rollback_to_savepoint
            alias_method :commit_db_transaction_without_promiscuous,   :commit_db_transaction
            alias_method :release_savepoint_without_promiscuous,       :release_savepoint

            def with_promiscuous_transaction_context(&block)
              ctx = Promiscuous::Publisher::Context.current
              block.call(ctx.transaction_context_of(:active_record)) if ctx
            end

            def begin_db_transaction
              # @current_xid = SecureRandom.uuid
              @transaction_prepared = false
              @current_xid = rand(1..1000000000).to_s
              begin_db_transaction_without_promiscuous
              with_promiscuous_transaction_context { |tx| tx.start }
            end

            def create_savepoint
              create_savepoint_without_promiscuous
              with_promiscuous_transaction_context { |tx| tx.start }
            end

            def rollback_db_transaction
              return if @transaction_prepared
              with_promiscuous_transaction_context { |tx| tx.rollback }
              rollback_db_transaction_without_promiscuous
              @current_xid = nil
            end

            def rollback_to_savepoint
              with_promiscuous_transaction_context { |tx| tx.rollback }
              rollback_to_savepoint_without_promiscuous
            end

            def commit_db_transaction
              ops = with_promiscuous_transaction_context { |tx| tx.write_operations_to_commit }
              PromiscuousTransaction.new(:connection => self,
                                         :transaction_id => @current_xid,
                                         :transaction_operations => ops).execute do
                commit_db_transaction_without_promiscuous
              end
              with_promiscuous_transaction_context { |tx| tx.commit }
              @current_xid = nil
            end

            def release_savepoint
              release_savepoint_without_promiscuous
              with_promiscuous_transaction_context { |tx| tx.commit }
            end

            alias_method :select_all_without_promiscuous, :select_all
            alias_method :select_values_without_promiscuous, :select_values
            alias_method :insert_without_promiscuous, :insert
            alias_method :update_without_promiscuous, :update
            alias_method :delete_without_promiscuous, :delete

            def select_all(arel, name = nil, binds = [])
              PromiscuousSelectOperation.new(arel, name, binds, :connection => self).execute do
                select_all_without_promiscuous(arel, name, binds)
              end
            end

            def select_values(arel, name = nil)
              PromiscuousSelectOperation.new(arel, name, [], :connection => self).execute do
                select_values_without_promiscuous(arel, name)
              end
            end

            def insert(arel, name = nil, pk = nil, id_value = nil, sequence_name = nil, binds = [])
              PromiscuousInsertOperation.new(arel, name, pk, id_value, sequence_name, binds, :connection => self).execute do
                insert_without_promiscuous(arel, name, pk, id_value, sequence_name, binds)
              end
            end

            def update(arel, name = nil, binds = [])
              PromiscuousUpdateOperation.new(arel, name, binds, :connection => self).execute do
                update_without_promiscuous(arel, name, binds)
              end
            end

            def delete(arel, name = nil, binds = [])
              PromiscuousDeleteOperation.new(arel, name, binds, :connection => self).execute do
                delete_without_promiscuous(arel, name, binds)
              end
            end
          end
        end
      end
    end
  end

  class PromiscousOperation < Promiscuous::Publisher::Operation::NonPersistent
    def initialize(arel, name, binds, options={})
      super(options)
      @arel = arel
      @operation_name = name
      @binds = binds
      @connection = options[:connection]
    end

    def transaction_context
      current_context.transaction_context_of(:active_record)
    end

    def ensure_transaction!
      if current_context && write? && !transaction_context.in_transaction?
        raise "You need to write to the database within an ActiveRecord transaction"
      end
    end

    def model
      @model ||= @arel.ast.relation.engine
      @model = nil unless @model < Promiscuous::Publisher::Model::ActiveRecord
      @model
    end

    def execute(&db_operation)
      return db_operation.call unless model
      return db_operation.call if Promiscuous.disabled?
      ensure_transaction!

      super do |query|
        query.non_instrumented { db_operation.call }
        query.instrumented do
          db_operation_and_select.tap do
            transaction_context.add_write_operation(self) if write? && !@instances.empty?
          end
        end
      end
    end

    def db_operation_and_select
      raise
    end

    def operation_payloads
      @instances.map do |instance|
        instance.promiscuous.payload(:with_attributes => self.operation.in?([:create, :update])).tap do |payload|
          payload[:operation] = self.operation
        end
      end
    end
  end

  class PromiscuousInsertOperation < PromiscousOperation
    def initialize(arel, name, pk, id_value, sequence_name, binds, options={})
      super(arel, name, binds, options)
      @pk = pk
      @id_value = id_value
      @sequence_name = sequence_name
      @operation = :create
      raise unless @arel.is_a?(Arel::InsertManager)
    end

    def db_operation_and_select
      # XXX This is only supported by Postgres and should be in the postgres driver

      if @connection.supports_returning_statments?
        @connection.exec_insert("#{@connection.to_sql(@arel, @binds)} RETURNING *", @operation_name, @binds).tap do |result|
          @instances = result.map { |row| model.instantiate(row) }
        end
        @instances.first.__send__(@pk)
      else
        @connection.exec_insert("#{@connection.to_sql(@arel, @binds)}", @operation_name, @binds)
        id = @binds.select { |k,v| k.name == 'id' }.first.last rescue nil
        id ||= @connection.instance_eval { @connection.last_id }
        id.tap do |last_id|
          result = @connection.exec_query("SELECT * FROM #{model.table_name} WHERE #{@pk} = #{last_id}")
          @instances = result.map { |row| model.instantiate(row) }
        end
      end
    end
  end

  class PromiscuousUpdateOperation < PromiscousOperation
    def initialize(arel, name, binds, options={})
      super
      @operation = :update
      return if Promiscuous.disabled?
      raise unless @arel.is_a?(Arel::UpdateManager)
    end

    def updated_fields_in_query
      Hash[@arel.ast.values.map do |v|
        case v
        when Arel::Nodes::Assignment
          [v.left.name.to_sym, v.right]
        when Arel::Nodes::SqlLiteral
          # Not parsing SQL, no thanks. It's an optimization anyway
          return nil
        else
          return nil
        end
      end]
    end

    def any_published_field_changed?
      updates = updated_fields_in_query
      return true if updates.nil? # Couldn't parse query
      (updated_fields_in_query.keys & model.published_db_fields).present?
    end

    def sql_select_statment
      arel = @arel.dup
      arel.instance_eval { @ast = @ast.dup }
      arel.ast.values = []
      arel.to_sql.sub(/^UPDATE /, 'SELECT * FROM ')
    end

    def db_operation_and_select
      if @connection.supports_returning_statments?
        @connection.exec_query("#{@connection.to_sql(@arel, @binds)} RETURNING *", @operation_name, @binds).tap do |result|
          @instances = result.map { |row| model.instantiate(row) }
        end.rows.size
      else
        @connection.exec_update(@connection.to_sql(@arel, @binds), @operation_name, @binds).tap do
          result = @connection.exec_query(sql_select_statment, @operation_name)
          @instances = result.map { |row| model.instantiate(row) }
        end
      end
    end

    def execute(&db_operation)
      return db_operation.call if Promiscuous.disabled?
      return db_operation.call unless  model
      return db_operation.call unless any_published_field_changed?
      super
    end
  end

  class PromiscuousDeleteOperation < PromiscousOperation
    def initialize(arel, name, binds, options={})
      super
      @operation = :destroy
      raise unless @arel.is_a?(Arel::DeleteManager)
    end

    def sql_select_statment
      @connection.to_sql(@arel.dup, @binds.dup).sub(/^DELETE /, 'SELECT * ')
    end

    def db_operation_and_select
      if @connection.supports_returning_statments?
        @connection.exec_query("#{@connection.to_sql(@arel, @binds)} RETURNING *", @operation_name, @binds).tap do |result|
          @instances = result.map { |row| model.instantiate(row) }
        end.rows.size
      else
        result = @connection.exec_query(sql_select_statment, @operation_name, @binds)
        @instances = result.map { |row| model.instantiate(row) }
        @connection.exec_delete(@connection.to_sql(@arel, @binds), @operation_name, @binds)
      end
    end
  end

  class PromiscuousSelectOperation < PromiscousOperation
    def initialize(arel, name, binds, options={})
      super
      @operation = :read
      @result = []
    end

    def model
      @model ||= begin
        case @arel
        when Arel::SelectManager
          raise "SQL statement too complicated (joins?)" if @arel.ast.cores.size != 1
          model = @arel.ast.cores.first.source.left.engine
        when ActiveRecord::Relation
          return nil # TODO
        else
          raise "What is this query?" unless @arel.is_a?(Arel::SelectManager)
        end

        model = nil unless model < Promiscuous::Publisher::Model::ActiveRecord
        model
      end
    rescue
      # TODO Track dependencies of complex queries properly...
      nil
    end

    def get_selector_instance
      attrs = @arel.ast.cores.first.wheres.map do |w|
        case w
        when Arel::Nodes::Grouping then nil
        else [w.children.first.left.name, w.children.first.right]
        end
      end.compact

      attrs = attrs.map do |key, value|
        case value
        when /^\$([0-9]+)$/ then [key, @binds[$1.to_i - 1][1]]
        else [key, value]
        end
      end

      model.instantiate(Hash[attrs])
    end

    def query_dependencies
      deps = dependencies_for(get_selector_instance)
      deps.empty? ? super : deps
    end

    def execute(&db_operation)
      # We dup because ActiveRecord modifies our return value
      super.tap { @result = @result.dup }
    end

    def db_operation_and_select
      # XXX This is only supported by Postgres.
      @connection.exec_query("#{@connection.to_sql(@arel, @binds)}", @operation_name, @binds).to_a.tap do |result|
        @instances = result.map { |row| model.instantiate(row.dup) }
      end
    end
  end

  class PromiscuousTransaction < Promiscuous::Publisher::Operation::Transaction
    attr_accessor :connection

    def initialize(options={})
      super
      # When we do a recovery, we use the default connection.
      @connection = options[:connection] || ActiveRecord::Base.connection
    end

    def execute_instrumented(query)
      query.prepare      { @connection.prepare_db_transaction }
      query.instrumented { @connection.commit_prepared_db_transaction(@transaction_id) }
      super
    end

    def self.recover_transaction(connection, transaction_id)
      op = new(:connection => connection, :transaction_id => transaction_id)
      # Getting the lock will trigger the real recovery mechanism
      lock_status = op.acquire_op_lock
      op.release_op_lock

      unless lock_status == :recovered
        # In the event where the recovery payload wasn't found, we must roll back.
        # If the operation was recoverable, but couldn't be recovered, an
        # exception would be thrown, so we won't roll it back by mistake.
        # If the operation was recovered, the roll back will result in an error,
        # which is fine.
        connection.rollback_prepared_db_transaction(transaction_id)
      end
    end
  end
end

module ActiveRecord::Persistence
  alias_method :touch_without_promiscuous, :touch
  def touch(name = nil)
    without_promiscuous { touch_without_promiscuous(name) }
  end
end

require "../type"
require "../pack_stream"
require "../pack_stream/packer"
require "../result"
require "./transaction"
require "./from_bolt"

require "socket"
require "openssl"

module Neo4j
  module Bolt
    class Connection
      GOGOBOLT = "\x60\x60\xB0\x17".to_slice
      SUPPORTED_VERSIONS = { 2, 0, 0, 0 }
      enum Commands
        Init       = 0x01
        Run        = 0x10
        PullAll    = 0x3F
        AckFailure = 0x0E
        Reset      = 0x0F
      end

      @connection : (TCPSocket | OpenSSL::SSL::Socket::Client)
      @transaction : Transaction?

      def initialize
        initialize "bolt://neo4j:neo4j@localhost:7687", ssl: false
      end

      def initialize(url : String)
        initialize URI.parse(url)
      end

      def initialize(url : String, ssl : Bool)
        initialize URI.parse(url), ssl
      end

      def initialize(@uri : URI, @ssl=true)
        host = uri.host.to_s
        port = uri.port || 7687
        username = uri.user.to_s
        password = uri.password.to_s

        if uri.scheme != "bolt"
          raise ArgumentError.new("Connection must use Bolt")
        end

        @connection = TCPSocket.new(host, port)

        if ssl
          context = OpenSSL::SSL::Context::Client.new
          context.add_options(OpenSSL::SSL::Options::NO_SSL_V2 | OpenSSL::SSL::Options::NO_SSL_V3)

          @connection = OpenSSL::SSL::Socket::Client.new(@connection, context)
        end

        handshake

        init username, password
      end

      def stream(_query, **parameters)
        stream(_query, parameters.to_h.transform_keys(&.to_s))
      end

      def stream(query, parameters = Hash(String, Type).new)
        StreamingResult.new(
          type: run(query, parameters),
          data: stream_results,
        )
      end

      private def stream_results
        write_message do |msg|
          msg.write_structure_start 0
          msg.write_byte Commands::PullAll
        end
        results = StreamingResultSet.new

        result = read_result
        case result
        when Success, Ignored
          results.complete!
        else
          spawn do
            until result.is_a?(Success) || result.is_a?(Ignored)
              results << result.as(List)
              result = read_result
            end
            results.complete!
          end
        end

        results
      end

      def execute(query, parameters : Map)
        if @transaction
          Result.new(type: run(query, parameters), data: pull_all)
        else
          transaction { execute query, parameters }
        end
      end

      def exec_cast(query : String, types : Tuple(*TYPES)) forall TYPES
        exec_cast query, Map.new, types
      end

      def exec_cast(query : String, parameters : NamedTuple, types : Tuple(*TYPES)) forall TYPES
        exec_cast query, parameters.to_h.transform_keys(&.to_s), types
      end

      def exec_cast(query : String, parameters : Map, types : Tuple(*TYPES)) forall TYPES
        run query, parameters

        write_message do |msg|
          msg.write_structure_start 0
          msg.write_byte Commands::PullAll
        end

        {% begin %}
          results = Array({{ TYPES.type_vars.map(&.stringify.gsub(/\.class$/, "").id).stringify.tr("[]", "{}").id }}).new

          result = read_raw_result
          until result[1] != 0x71
            # First 3 bytes are Structure, Record, and List
            # TODO: If the RETURN clause in the query has more than 16 items,
            # this will break because the List byte marker and its size won't be
            # in a single byte. We'll need to detect this here.
            io = IO::Memory.new(result + 3)
            results << {
              {% for type in TYPES %}
                {{type.stringify.gsub(/\.class$/, "").id}}.from_bolt(io),
              {% end %}
            }
            result = read_raw_result
          end

          results
        {% end %}
      end

      def execute(query, **params)
        params_hash = Map.new

        params.each { |key, value| params_hash[key.to_s] = value }

        execute query, params_hash
      end

      def transaction
        if @transaction
          raise NestedTransactionError.new("Transaction already open, cannot open a new transaction")
        end

        @transaction = Transaction.new(self)

        execute "BEGIN"
        yield(@transaction.not_nil!).tap { execute "COMMIT" }
      rescue RollbackException
        execute "ROLLBACK"
      rescue e : NestedTransactionError
        # We don't want our NestedTransactionError to be picked up by the
        # catch-all rescue below, so we're explicitly capturing and re-raising
        # here to bypass it
        reset
        raise e
      rescue e : QueryException
        ack_failure
        execute "ROLLBACK"
        reset
        raise e
      rescue e # Don't ack_failure if it wasn't a QueryException
        execute "ROLLBACK"
        reset
        raise e
      ensure
        @transaction = nil
      end

      def close
        @connection.close
      end

      # If the connection gets into a wonky state, this method tells the server
      # to reset it back to a normal state, but you lose everything you haven't
      # pulled down yet.
      def reset
        write_message do |msg|
          msg.write_structure_start 0
          msg.write_byte Commands::Reset
        end
        read_result
      end

      private def ack_failure
        write_message do |msg|
          msg.write_structure_start 0
          msg.write_byte Commands::AckFailure
        end
        read_result
      end

      private def init(username, password)
        write_message do |msg|
          msg.write_structure_start 1
          msg.write_byte Commands::Init
          msg.write "Neo4j.cr/0.1.0"
          msg.write({
            "scheme" => "basic",
            "principal" => username,
            "credentials" => password,
          })
        end

        case result = read_result
        when Success
          result
        when Failure
          raise Exception.new(result.inspect)
        else
          raise Exception.new("Don't know how to handle result: #{result.inspect}")
        end
      end

      private def write_message
        packer = PackStream::Packer.new
        yield packer

        slice = packer.to_slice
        length = slice.size

        message = IO::Memory.new.tap { |io|
          io.write_bytes length.to_u16, IO::ByteFormat::BigEndian
          io.write slice
          io.write_bytes 0x0000.to_u16, IO::ByteFormat::BigEndian
        }.to_slice
        @connection.write message
        @connection.flush
      end

      private def run(statement, parameters = {} of String => Type, retries = 5)
        write_message do |msg|
          msg.write_structure_start 2
          msg.write_byte Commands::Run
          msg.write statement
          msg.write parameters
        end

        result = read_result
        case result
        when Failure
          raise ::Neo4j::QueryException.new(result.attrs["message"].as(String), result.attrs["code"].as(String))
        when Success, Ignored
          result
        else
          raise ::Neo4j::UnknownResult.new("Cannot identify this result: #{result.inspect}")
        end
      rescue ex : IO::EOFError | OpenSSL::SSL::Error | Errno
        if retries > 0
          initialize @uri, @ssl
          run statement, parameters, retries - 1
        else
          raise ex
        end
      end

      private def pull_all
        write_message do |msg|
          msg.write_structure_start 0
          msg.write_byte Commands::PullAll
        end

        results = Array(List).new
        result = read_result

        until result.is_a?(Success) || result.is_a?(Ignored)
          results << result.as(List)
          result = read_result
        end

        results
      end

      private def read_result
        PackStream.unpack(read_raw_result).tap do |result|
          if result.is_a? Failure
            raise ::Neo4j::QueryException.new(result.attrs["message"].as(String), result.attrs["code"].as(String))
          end
        end
      end

      # Read a single result from the server in 64kb chunks. This is a bit of a
      # naive implementation that buffers the chunks until it has the full
      # result, then flattens out the chunks into a single slice and parses
      # that slice. 
      private def read_raw_result
        length = 1_u16
        messages = [] of Bytes
        length = @connection.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        while length != 0x0000
          bytes = Bytes.new(length)
          @connection.read_fully bytes
          messages << bytes
          length = @connection.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        end

        bytes = Bytes.new(messages.map(&.size).sum)
        current_byte = 0
        messages.reduce(bytes) do |chunk, msg|
          msg.copy_to chunk
          current_byte += msg.size

          bytes + current_byte
        end

        bytes
      end

      private def write(value)
        @connection.write_bytes value, IO::ByteFormat::BigEndian
        @connection.flush
      end

      private def write_value(value)
        @connection.write PackStream.pack(value)
      end

      private def handshake
        @connection.write GOGOBOLT
        SUPPORTED_VERSIONS.each do |ver|
          @connection.write_bytes ver, IO::ByteFormat::BigEndian
        end
        @connection.flush

        # Read server version
        # @todo Verify this
        @connection.read_bytes(
          Int32,
          IO::ByteFormat::BigEndian
        )
      end

      private def send_message(string : String)
        send_message string.to_slice
      end

      private def send_message(bytes : Bytes)
        @connection.write bytes
      end
    end
  end

  class StreamingResultSet
    include Iterable(List)

    delegate complete!, to: @iterator

    def initialize
      @iterator = Iterator.new
    end

    def <<(value : List) : self
      @iterator.channel.send value
      self
    end

    def each
      @iterator
    end

    class Iterator
      include ::Iterator(List)

      getter channel

      def initialize
        @channel = Channel(List).new(1)
        @complete = false
      end

      def next
        if @complete && @channel.empty?
          stop
        else
          @channel.receive
        end
      end

      def complete!
        @complete = true
      end
    end
  end

  class StreamingResult
    include Iterable(List)
    include Enumerable(List)

    getter type, data

    def initialize(
      @type : Success | Ignored,
      @data : StreamingResultSet,
    )
    end

    def each
      @data.each
    end

    def each(&block : List ->)
      each.each do |row|
        yield row
      end
    end
  end
end

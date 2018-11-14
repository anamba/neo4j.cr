require "./lexer"

module Neo4j
  module PackStream
    struct Unpacker
      enum StructureTypes : Int8
        Node                = 0x4e
        Relationship        = 0x52
        Path                = 0x50
        UnboundRelationship = 0x72
        Success             = 0x70
        Failure             = 0x7f
        Ignored             = 0x7e
        Record              = 0x71
      end

      def initialize(string_or_io)
        @lexer = Lexer.new(string_or_io)
      end

      def read
        read_value
      end

      def read_nil
        next_token
        check :nil
        nil
      end

      def read_nil_or
        token = prefetch_token
        if token.type == :nil
          token.used = true
          nil
        else
          yield
        end
      end

      def read_bool
        next_token
        case token.type
        when :true
          true
        when :false
          false
        else
          unexpected_token
        end
      end

      def read_numeric
        next_token
        case token.type
        when :INT
          token.int_value
        when :FLOAT
          token.float_value
        else
          unexpected_token
        end
      end

      {% for type in %w(int uint float string binary) %}
        def read_{{type.id}}                          # def read_int
          next_token
          check :{{type.id.upcase}}                   #   check :INT
          token.{{type.id}}_value                     #   token.int_value
        end                                           # end
      {% end %}

      def read_array(fetch_next_token = true)
        next_token if fetch_next_token
        check :ARRAY
        Array(Type).new(token.size.to_i32) do
          read_value
        end
      end

      def read_hash(read_key = true, fetch_next_token = true)
        next_token if fetch_next_token
        check :HASH
        token.size.times do
          if read_key
            key = read_value
            yield key
          else
            yield nil
          end
        end
      end

      def read_hash(fetch_next_token = true)
        next_token if fetch_next_token
        check :HASH
        hash = Hash(String, Type).new(initial_capacity: token.size.to_i32)
        token.size.times do
          key = read_string
          value = read_value
          hash[key] = value
        end
        hash
      end

      def read_structure(fetch_next_token = true)
        next_token if fetch_next_token
        check :STRUCTURE

        structure_type = read_value

        case structure_type
        when StructureTypes::Node.value
          id = read_numeric.to_i32
          labels = read_array.map(&.to_s)
          props = read_hash
            .each_with_object({} of String => Type) { |(k, v), h|
              h[k.to_s] = v }
          Node.new(id, labels, props)
        when StructureTypes::Relationship.value
          Relationship.new(
            id: read_numeric.to_i32,
            start: read_numeric.to_i32,
            end: read_numeric.to_i32,
            type: read_string,
            properties: read_hash
              .each_with_object({} of String => Type) { |(k, v), h|
                h[k.to_s] = v }
          )
        when StructureTypes::Path.value
          Path.new(
            nodes: read_array.map { |node| node.as(Node) },
            relationships: read_array.map(&.as(UnboundRelationship)),
            sequence: read_array.map(&.as(Int8)),
          )
        when StructureTypes::UnboundRelationship.value
          UnboundRelationship.new(
            id: read_numeric.to_i32,
            type: read_string,
            properties: read_hash
              .each_with_object({} of String => Type) { |(k, v), h|
                h[k.to_s] = v }
          )
        when StructureTypes::Success.value
          Success.new(read_hash)
        when StructureTypes::Failure.value
          Failure.new(read_hash)
        when StructureTypes::Ignored.value
          Ignored.new
        when StructureTypes::Record.value
          read_value
        else
          Array(Type).new(token.size) do
            read_value
          end
        end
      end

      def read_structure(fetch_next_token = true)
        next_token if fetch_next_token

        check :STRUCTURE
        token.size.times { yield }
      end

      def read_value : Type
        next_token

        case token.type
        when :INT
          token.int_value
        when :FLOAT
          token.float_value
        when :STRING
          token.string_value
        when :nil
          nil
        when :true
          true
        when :false
          false
        when :ARRAY
          read_array fetch_next_token: false
        when :HASH
          read_hash fetch_next_token: false
        when :STRUCTURE
          read_structure fetch_next_token: false
        else
          unexpected_token token.type
        end
      end

      private delegate token, to: @lexer
      private delegate next_token, to: @lexer
      delegate prefetch_token, to: @lexer

      private def check(token_type)
        unexpected_token(token_type) unless token.type == token_type
      end

      private def unexpected_token(token_type = nil)
        message = "unexpected token '#{token}'"
        message += " expected #{token_type}" if token_type
        raise UnpackException.new(message, @lexer.byte_number)
      end
    end
  end
end

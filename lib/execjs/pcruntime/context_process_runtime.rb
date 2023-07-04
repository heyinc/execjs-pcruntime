# frozen_string_literal: true
require "execjs/runtime"
require "tmpdir"
require "json"
require "net/protocol"
require "net/http"

module ExecJS
  module PCRuntime
    class ContextProcessRuntime < Runtime
      class Context < Runtime::Context
        def initialize(runtime, source = "", options = {})
          super(runtime, source, options)

          # puts "[#{__FILE__}:#{__LINE__}] Context::initialize"
          source = source.encode('UTF-8')

          # @type [JSRuntimeHandle]
          @runtime = runtime.create_runtime_handle

          # Test compile context source

          @runtime.evaluate(source.encode('UTF-8'))
        end

        def eval(source, options = {})
          # puts "[#{__FILE__}:#{__LINE__}] Context::eval"
          if /\S/ =~ source
            @runtime.evaluate("(#{source.encode('UTF-8')})")
          end
        end

        def exec(source, options = {})
          # puts "[#{__FILE__}:#{__LINE__}] Context::exec"

          @runtime.evaluate("(()=>{#{source.encode('UTF-8')}})()")
        end

        def call(identifier, *args)
          # puts "[#{__FILE__}:#{__LINE__}] Context::call"

          @runtime.evaluate("(#{identifier}).apply(this, #{::JSON.generate(args)})")
        end

        protected

        def extract_result(output, filename)
          status, value, stack = output.empty? ? [] : ::JSON.parse(output, create_additions: false)
          if status == "ok"
            value
          else
            stack ||= ""
            real_filename = File.realpath(filename)
            stack = stack.split("\n").map do |line|
              line.sub(" at ", "")
                  .sub(real_filename, "(execjs)")
                  .sub(filename, "(execjs)")
                  .strip
            end
            stack.reject! { |line| ["eval code", "eval code@", "eval@[native code]"].include?(line) }
            stack.shift unless stack[0].to_s.include?("(execjs)")
            error_class = value =~ /SyntaxError:/ ? RuntimeError : ProgramError
            error = error_class.new(value)
            error.set_backtrace(stack + caller)
            raise error
          end
        end
      end

      class JSRuntimeHandle
        # @param [String] binary node(またはそれに準ずるJavaScriptランタイム)バイナリのパス
        # @param [String] initial_source 初期状態で読み込ませるJavaScriptソースコードのパス
        def initialize(binary, initial_source)
          Dir::Tmpname.create "execjs_pcruntime" do |path|
            @process = Process.spawn({ "PORT" => path }, binary, initial_source)

            retries = 20
            until File.exist?(path)
              sleep 0.05
              retries -= 1

              if retries <= 0
                begin
                  Process.kill(:KILL, @process)
                ensure
                  raise Errno::EEXIST
                end
              end
            end

            @socket_path = path

            begin
              # nodejsの起動に失敗しているとここでエラーが出るため、Dir::Tmpname.createに渡したブロック全体が再実行される
              post_request("/")
            rescue
              begin
                Process.kill(:KILL, @process)
              ensure
                raise Errno::EEXIST
              end
            end
          end
          p = @process
          ObjectSpace.define_finalizer(self, self.class.finalizer(@process))
        end

        def JSRuntimeHandle.finalizer(process)
          proc do
            Process.kill(:KILL, process)
          rescue => e
            puts e
          end
        end

        # @param [String] source JavaScriptソース
        # @return [object]
        def evaluate(source)
          post_request("/eval", "text/javascript", source)
        end

        private

        # thread-localなsocketを返す
        # @return [Net::BufferedIO]
        def get_socket
          Net::BufferedIO.new(UNIXSocket.new(@socket_path))
        end

        # @param [String] path HTTPリクエスト時のPath("/eval"など)
        # @param [String?] content_type bodyのContent-type
        # @param [String] body HTTPリクエストのbody
        # @return [object?]
        def post_request(path, content_type = nil, body = nil)
          socket = get_socket

          # IOでタイムアウトが発生したのでとりあえず伸ばして対処
          socket.read_timeout *= 100
          socket.write_timeout *= 100
          # puts "[#{__FILE__}:#{__LINE__}] socket.read_timeout=#{socket.read_timeout}"
          # puts "[#{__FILE__}:#{__LINE__}] socket.write_timeout=#{socket.write_timeout}"

          request = Net::HTTP::Post.new(path)
          request['Connection'] = 'close'
          if content_type != nil
            request['Content-Type'] = content_type
            request.body = body
          end

          # Net::HTTPGenericRequest#exec internal use onlyとマークされているので使いたくない 代替案はNet::HTTP#requestのoverride(めんどいので保留)
          begin
            request.exec(socket, "1.1", path)
          rescue => e
            raise e
          end

          begin
            response = Net::HTTPResponse.read_new(socket)
          end while response.kind_of?(Net::HTTPContinue)
          response.reading_body(socket, request.response_body_permitted?) {}
          if response.code == "200"
            result = response.body
            if /\S/ =~ result
              ::JSON.parse(response.body, create_additions: false)
            end
          else
            message, stack = response.body.split "\0"
            error_class = message =~ /SyntaxError:/ ? RuntimeError : ProgramError
            error = error_class.new(message)
            error.set_backtrace(stack)
            raise error
          end
        end
      end

      attr_reader :name

      def initialize(options)
        super()
        @name = options[:name]
        @command = options[:command]
        @runner_path = options[:runner_path]
        @binary = nil
      end

      def available?
        require 'json'
        binary ? true : false
      end

      def deprecated?
        @deprecated
      end

      # @return [JSRuntimeHandle]
      def create_runtime_handle
        JSRuntimeHandle.new(binary, @runner_path)
      end

      private

      def binary
        @binary ||= which(@command)
      end

      def locate_executable(command)
        commands = Array(command)
        if ExecJS.windows? && File.extname(command) == ""
          ENV['PATHEXT'].split(File::PATH_SEPARATOR).each { |p|
            commands << (command + p)
          }
        end

        commands.find { |cmd|
          if File.executable? cmd
            cmd
          else
            path = ENV['PATH'].split(File::PATH_SEPARATOR).find { |p|
              full_path = File.join(p, cmd)
              File.executable?(full_path) && File.file?(full_path)
            }
            path && File.expand_path(cmd, path)
          end
        }
      end

      protected

      def json2_source
        @json2_source ||= IO.read(ExecJS.root + "/support/json2.js")
      end

      def encode_source(source)
        encoded_source = encode_unicode_codepoints(source)
        ::JSON.generate("(function(){ #{encoded_source} })()", quirks_mode: true)
      end

      def encode_unicode_codepoints(str)
        str.gsub(/[\u0080-\uffff]/) do |ch|
          "\\u%04x" % ch.codepoints.to_a
        end
      end

      def which(command)
        Array(command).find do |name|
          name, args = name.split(/\s+/, 2)
          path = locate_executable(name)

          next unless path

          args ? "#{path} #{args}" : path
        end
      end
    end
  end
end
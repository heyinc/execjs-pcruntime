# frozen_string_literal: true
require "execjs/runtime"
require "tmpdir"
require "json"
require "net/protocol"
require "net/http"

module ExecJS
  module PCRuntime
    # override ExecJS::Runtime
    class ContextProcessRuntime < Runtime
      # override ExecJS::Runtime::Context
      class Context < Runtime::Context
        # @param [String] runtime ContextProcessRuntimeのインスタンスを期待
        # @param [String] source 起動時に読み込むJavaScriptソース
        # @param [any] options
        def initialize(runtime, source = "", options = {})
          super(runtime, source, options)

          # @type [JSRuntimeHandle]
          @runtime = runtime.create_runtime_handle

          # Contextに初期ソースを入れ込む
          @runtime.evaluate(source.encode('UTF-8'))
        end

        # override ExecJS::Runtime::Context#eval
        # @param [String] source
        # @param [any] options
        def eval(source, options = {})
          if /\S/ =~ source
            @runtime.evaluate("(#{source.encode('UTF-8')})")
          end
        end

        # override ExecJS::Runtime::Context#exec
        # @param [String] source
        # @param [any] options
        def exec(source, options = {})
          @runtime.evaluate("(()=>{#{source.encode('UTF-8')}})()")
        end

        # override ExecJS::Runtime:Context#call
        # @param [String] identifier
        # @param [Array<_ToJson>] args
        def call(identifier, *args)
          @runtime.evaluate("(#{identifier}).apply(this, #{::JSON.generate(args)})")
        end
      end

      # JavaScriptランタイムのハンドル
      # コンストラクタで起動して、finalizerで終了処理をする
      class JSRuntimeHandle
        # @param [Array<String>] binary node(またはそれに準ずるJavaScriptランタイム)バイナリの起動コマンド ["node"] ["deno", "run"]など
        # @param [String] initial_source 初期状態で読み込ませるJavaScriptソースコードのパス
        def initialize(binary, initial_source)
          Dir::Tmpname.create "execjs_pcruntime" do |path|
            @runtime_pid = Process.spawn({ "PORT" => path }, *binary, initial_source)

            retries = 20
            until File.exist?(path)
              sleep 0.05
              retries -= 1

              if retries <= 0
                begin
                  Process.kill(:KILL, @runtime_pid)
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
                Process.kill(:KILL, @runtime_pid)
              ensure
                raise Errno::EEXIST
              end
            end
          end
          ObjectSpace.define_finalizer(self, self.class.finalizer(@runtime_pid))
        end

        # JavaScriptコードを評価してその結果を返す
        # JavaScript側のエラーはRuby側に透過する
        # @param [String] source JavaScriptソース
        # @return [object]
        def evaluate(source)
          post_request("/eval", "text/javascript", source)
        end

        private

        # 指定IDのプロセスをkillするprocedureを返す
        # JSRuntimeHandleのfinalizerとして使う
        # @param [Integer] pid
        def JSRuntimeHandle.finalizer(pid)
          proc do
            Process.kill(:KILL, pid)
          rescue => e
            STDERR.puts e
          end
        end

        # プロセスに繋がったsocketを作って返す
        # @return [Net::BufferedIO]
        def get_socket
          Net::BufferedIO.new(UNIXSocket.new(@socket_path))
        end

        # JavaScriptランタイムにリクエストを送る
        # @param [String] path HTTPリクエスト時のPath("/eval"など)
        # @param [String?] content_type bodyのContent-type
        # @param [String] body HTTPリクエストのbody
        # @return [object?]
        def post_request(path, content_type = nil, body = nil)
          socket = get_socket

          # IOでタイムアウトが発生したのでとりあえず伸ばして対処
          socket.read_timeout *= 100
          socket.write_timeout *= 100

          request = Net::HTTP::Post.new(path)
          request['Connection'] = 'close'
          if content_type != nil
            request['Content-Type'] = content_type
            request.body = body
          end

          # Net::HTTPGenericRequest#exec internal use onlyとマークされているので使いたくない 代替案はNet::HTTP#requestのoverride(めんどいので保留)
          request.exec(socket, "1.1", path)

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

      # @param [String] name ランタイムの名称
      # @param [Array<String>] command JavaScriptランタイムのコマンド候補 ["deno run", "node"] など
      # @param [String] runner_path JavaScriptランタイムで実行するjsファイルのパス
      def initialize(name, command, runner_path = File.expand_path('../runner.js', __FILE__), deprecated = false)
        super()
        @name = name
        @command = command
        @runner_path = runner_path
        @binary = nil
        @deprecated = deprecated
      end

      # override ExecJS::Runtime#available?
      def available?
        require 'json'
        binary ? true : false
      end

      # override ExecJS::Runtime#deprecated?
      def deprecated?
        @deprecated
      end

      # JavaScriptランタイムを起動してそのハンドルを返す
      # @return [JSRuntimeHandle]
      def create_runtime_handle
        JSRuntimeHandle.new(binary, @runner_path)
      end

      private

      # JavaScriptランタイムの起動コマンドを返す
      # コンストラクタで渡されたコマンドを遅延評価かつキャッシュ
      # @return [Array<String>]
      def binary
        @binary ||= which(@command)
      end

      # @param [Array<String>] commands コマンドの候補 ["deno run", "node"] など
      # @return [Array<String>] コマンドの絶対パスとコマンドライン引数 ["deno", "run"] など
      def which(commands)
        extensions = ExecJS.windows? ? ENV['PATHEXT'].split(File::PATH_SEPARATOR) + [""] : [""]
        search_set = (ENV['PATH'].split(File::PATH_SEPARATOR) + [""])
                     .flat_map { |base_path| extensions.map { |ext| [base_path, ext] } }
        regex = /([^\s"']+)|"([^"]+)"|'([^']+)'(?:\s+|\s*\Z)/
        commands.each do |command|
          command_item = []
          command.scan(regex) { |match| command_item << Array(match).flatten.find { |c| c } }
          command, *args = command_item
          commands = search_set.filter_map do |setting|
            base_path, extension = setting
            executable_path = base_path != "" ? File.join(base_path, command + extension) : command + extension
            File.executable?(executable_path) && File.exist?(executable_path) ? executable_path : nil
          end
          command = commands.first
          return [command] + args unless command.nil?
        end
      end
    end
  end
end
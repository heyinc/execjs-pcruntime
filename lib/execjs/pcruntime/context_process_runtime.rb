# frozen_string_literal: true

require 'execjs/runtime'
require 'tmpdir'
require 'json'
require 'net/protocol'
require 'net/http'

module ExecJS
  module PCRuntime
    # override ExecJS::Runtime
    class ContextProcessRuntime < Runtime
      # override ExecJS::Runtime::Context
      class Context < Runtime::Context
        # @param [String] runtime ContextProcessRuntimeのインスタンスを期待
        # @param [String] source 起動時に読み込むJavaScriptソース
        # @param [any] options
        def initialize(runtime, source = '', options = {})
          super(runtime, source, options)

          # @type [JSRuntimeHandle]
          @runtime = runtime.create_runtime_handle

          # Contextに初期ソースを入れ込む
          @runtime.evaluate(source.encode('UTF-8'))
        end

        # override ExecJS::Runtime::Context#eval
        # @param [String] source
        # @param [any] options
        def eval(source, _options = {})
          return unless /\S/.match?(source)

          @runtime.evaluate("(#{source.encode('UTF-8')})")
        end

        # override ExecJS::Runtime::Context#exec
        # @param [String] source
        # @param [any] options
        def exec(source, _options = {})
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
          Dir::Tmpname.create 'execjs_pcruntime' do |path|
            @runtime_pid = create_process(path, *binary, initial_source)
            @socket_path = path
          end
          ObjectSpace.define_finalizer(self, self.class.finalizer(@runtime_pid))
        end

        def delayed_retries(times)
          while times.positive?
            return true if yield

            sleep 0.05
            times -= 1
          end
          false
        end

        def self.kill_process(pid)
          Process.kill(:KILL, pid)
          nil
        rescue StandardError => e
          e
        end

        def create_process(socket_path, *command)
          pid = Process.spawn({ 'PORT' => socket_path }, *command)

          unless delayed_retries(20) { File.exist?(socket_path) }
            kill_process(pid)
            raise Errno::EEXIST
          end

          begin
            # nodejsの起動に失敗しているとここでエラーが出るため、Dir::Tmpname.createに渡したブロック全体が再実行される
            post_request(socket_path, '/')
          rescue StandardError
            kill_process(pid)
            raise Errno::EEXIST
          end
          pid
        end

        # JavaScriptコードを評価してその結果を返す
        # JavaScript側のエラーはRuby側に透過する
        # @param [String] source JavaScriptソース
        # @return [object]
        def evaluate(source)
          post_request(@socket_path, '/eval', 'text/javascript', source)
        end

        # 指定IDのプロセスをkillするprocedureを返す
        # JSRuntimeHandleのfinalizerとして使う
        # @param [Integer] pid
        def self.finalizer(pid)
          proc do
            err = kill_process(pid)
            warn err.full_message unless err.nil?
          end
        end

        private

        # プロセスに繋がったsocketを作って返す
        # @return [Net::BufferedIO]
        def create_socket(socket_path)
          Net::BufferedIO.new(UNIXSocket.new(socket_path))
        end

        # JavaScriptランタイムにリクエストを送る
        # @param [String] socket_path UNIXドメインソケットのパス
        # @param [String] path HTTPリクエスト時のPath("/eval"など)
        # @param [String?] content_type bodyのContent-type
        # @param [String] body HTTPリクエストのbody
        # @return [object?]
        # これ以上分割する意味が特になさそうかつ単純な順次処理なのでlintエラー抑制で対処
        # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        def post_request(socket_path, path, content_type = nil, body = nil)
          socket = create_socket socket_path

          # IOでタイムアウトが発生したのでとりあえず伸ばして対処
          socket.read_timeout *= 100
          socket.write_timeout *= 100

          request = Net::HTTP::Post.new(path)
          request['Connection'] = 'close'
          unless content_type.nil?
            request['Content-Type'] = content_type
            request.body = body
          end

          # Net::HTTPGenericRequest#exec internal use onlyとマークされているので使いたくない 代替案はNet::HTTP#requestのoverride(めんどいので保留)
          request.exec(socket, '1.1', path)

          # rubocopの提案を採用すると動作が変わって無限ループになるので抑制
          # rubocop:disable Lint/Loop
          begin
            response = Net::HTTPResponse.read_new(socket)
          end while response.is_a?(Net::HTTPContinue)
          # rubocop:enable Lint/Loop
          response.reading_body(socket, request.response_body_permitted?) {}

          if response.code == '200'
            result = response.body
            ::JSON.parse(response.body, create_additions: false) if /\S/.match?(result)
          else
            message, stack = response.body.split "\0"
            error_class = /SyntaxError:/.match?(message) ? RuntimeError : ProgramError
            error = error_class.new(message)
            error.set_backtrace(stack)
            raise error
          end
        end
        # rubocop:enable Metrics/MethodLength,Metrics/AbcSize
      end

      attr_reader :name

      # @param [String] name ランタイムの名称
      # @param [Array<String>] command JavaScriptランタイムのコマンド候補 ["deno run", "node"] など
      # @param [String] runner_path JavaScriptランタイムで実行するjsファイルのパス
      def initialize(name, command, runner_path = File.expand_path('runner.js', __dir__), deprecated: false)
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
        commands.each do |command|
          command, *args = split_command_string command
          command = search_executable_path command
          return [command] + args unless command.nil?
        end
      end

      # コマンドから絶対パスを検索する
      # @param [String] command コマンド名
      # @return [String, nil] コマンドの絶対パス 見つからなかった場合はnil
      # これ以上メソッド分割すると却って読みにくくなりそうなので抑制
      # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      def search_executable_path(command)
        @extensions ||= ExecJS.windows? ? ENV['PATHEXT'].split(File::PATH_SEPARATOR) + [''] : ['']
        @path ||= ENV['PATH'].split(File::PATH_SEPARATOR) + ['']
        @path.each do |base_path|
          @extensions.each do |extension|
            executable_path = base_path == '' ? command + extension : File.join(base_path, command + extension)
            return executable_path if File.executable?(executable_path) && File.exist?(executable_path)
          end
        end
        nil
      end
      # rubocop:enable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity

      # コマンド文字列を分割する
      #   split_command_string "deno run" # ["deno", "run"]
      # @param [String] command コマンド文字列
      # @return [Array<String>] 分割された配列
      def split_command_string(command)
        regex = /([^\s"']+)|"([^"]+)"|'([^']+)'(?:\s+|\s*\Z)/
        command.scan(regex).flatten.compact
      end
    end
  end
end

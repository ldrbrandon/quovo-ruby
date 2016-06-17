module Quovo
  module Request
    using Quovo::Refinements::Sensitive

    def request(method, path, params = {}, format = :plain, config = Quovo.config)
      return fake_request(method, path, params, &Proc.new) if Quovo.fake?

      request = build_http_request(config.endpoint, method, path, params)

      yield(request) if block_given?

      do_http_request(request, config.request_timeout, format) do |code, payload, elapsed|
        Quovo.run_hooks!(
          path,
          method.to_s.upcase,
          strip_sensitive(params, config),
          code,
          strip_sensitive(payload, config),
          elapsed
        )
        payload
      end
    end

    protected

    def build_http_request(endpoint, method, path, params)
      request = case method
                when :get
                  Net::HTTP::Get
                when :post
                  Net::HTTP::Post
                when :put
                  Net::HTTP::Put
                when :delete
                  Net::HTTP::Delete
                else
                  raise Quovo::HttpError, 'unsupported method'
                end.new(URI(endpoint + path))

      inject_http_params(request, method, params) if params.any?
      request
    end

    def http_transport(uri)
      Net::HTTP.new(uri.host, uri.port)
    end

    private

    def do_http_request(request, timeout, format)
      http              = http_transport(request.uri)
      http.read_timeout = timeout
      http.use_ssl      = true
      http.verify_mode  = OpenSSL::SSL::VERIFY_NONE

      http.start do |transport|
        (code, payload), elapsed = with_timing { parse_response(transport.request(request), format) }
        yield(code, payload, elapsed)
      end
    end

    def inject_http_params(request, method, params)
      if method == :get
        request.uri.query = URI.encode_www_form(params)
      else
        request.body = params.to_json
        request['Content-Type'] = 'application/json'
      end
    end

    def parse_response(response, format)
      code = response.code
      body = response.body
      payload = format == :json ? JSON.parse(body) : body
      raise Quovo::NotFoundError,  body if code =~ /404/
      raise Quovo::ForbiddenError, body if code =~ /403/
      raise Quovo::HttpError,      body if code =~ /^[45]/
      [code, payload]
    end

    def with_timing
      start_at = Time.now
      result   = yield
      elapsed  = (Time.now - start_at).round(3)
      [result, elapsed]
    end

    def strip_sensitive(data, config)
      config.strip_sensitive_params ? data.strip_sensitive : data
    end

    class FakeRequest
      attr_reader :username, :password
      def basic_auth(username, password)
        @username = username
        @password = password
      end

      def []=(_, __)
        {}
      end
    end

    def fake_request(method, path, params)
      fake = Quovo.fake_calls.find do |fake_method, fake_path, fake_params, _|
        fake_method == method && fake_path == path && (fake_params == params || fake_params == '*')
      end
      raise StubNotFoundError, [method, path, params] unless fake
      yield(FakeRequest.new) if block_given?
      fake.last
    end
  end
end

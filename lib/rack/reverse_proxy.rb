require 'net/http'
require 'net/https'
require "rack-proxy"
require "rack/reverse_proxy_matcher"
require "rack/exception"

module Rack
  class ReverseProxy
    include NewRelic::Agent::Instrumentation::ControllerInstrumentation if defined? NewRelic

    def initialize(app = nil, &b)
      @app = app || lambda {|env| [404, [], []] }
      @matchers = []
      @global_options = {:preserve_host => true, :x_forwarded_host => true, :matching => :all, :replace_response_host => false}
      instance_eval &b if block_given?
    end

    def call(env)
      rackreq = Rack::Request.new(env)
      matcher = get_matcher(rackreq.fullpath, extract_http_request_headers(rackreq.env), rackreq)
      return @app.call(env) if matcher.nil?

      if @global_options[:newrelic_instrumentation]
        action_name = "#{rackreq.path.gsub(/\/\d+/,'/:id').gsub(/^\//,'')}/#{rackreq.request_method}" # Rack::ReverseProxy/foo/bar#GET
        perform_action_with_newrelic_trace(:name => action_name, :request => rackreq) do
          proxy(env, rackreq, matcher)
        end
      else
        proxy(env, rackreq, matcher)
      end
    end

    private

    def proxy(env, source_request, matcher)
      uri = matcher.get_uri(source_request.fullpath,env)
      if uri.nil?
        return @app.call(env)
      end
      options = @global_options.dup.merge(matcher.options)

      # Initialize request
      target_request = Net::HTTP.const_get(source_request.request_method.capitalize).new(uri.request_uri)

      # Setup headers
      target_request_headers = extract_http_request_headers(source_request.env)

      if options[:preserve_host]
        target_request_headers['HOST'] = "#{uri.host}:#{uri.port}"
      end

      if options[:x_forwarded_host]
        target_request_headers['X-Forwarded-Host'] = source_request.host
        target_request_headers['X-Forwarded-Port'] = "#{source_request.port}"
      end

      # Modify request headers
      modify_request_headers(target_request_headers, matcher)

      target_request.initialize_http_header(target_request_headers)

      # Basic auth
      target_request.basic_auth options[:username], options[:password] if options[:username] and options[:password]

      # Setup body
      if target_request.request_body_permitted? && source_request.body
        source_request.body.rewind
        target_request.body_stream    = source_request.body
      end

      target_request.content_length = source_request.content_length || 0
      if target_request.content_length > 0
        target_request.content_type   = 'application/json'
      elsif source_request.content_type
        target_request.content_type   = source_request.content_type
      end

      # Create a streaming response (the actual network communication is deferred, a.k.a. streamed)
      target_response = HttpStreamingResponse.new(target_request, uri.host, uri.port)

      target_response.use_ssl = "https" == uri.scheme

      # Let rack set the transfer-encoding header
      response_headers = target_response.headers
      response_headers.delete('transfer-encoding')

      # Replace the location header with the proxy domain
      if response_headers['location'] && options[:replace_response_host]
        response_location = URI(response_headers['location'][0])
        response_location.host = source_request.host
        response_headers['location'] = response_location.to_s
      end

      # Modify response
      target_response_body = target_response.body.to_s
      if response_headers.include?('content-encoding') && response_headers['content-encoding'].include?('gzip')
        response_headers.delete('content-encoding')
        response_body = ''
        modify_response_headers(response_headers, matcher)
        body_expanded = StringIO.open(target_response_body, 'rb') do |sio|
          Zlib::GzipReader.wrap(sio).read
        end
        body_modified = modify_response_body(body_expanded, matcher)
        response_headers.delete('content-length')
        # response_headers['content-length'] = [body_modified.bytesize.to_s]
        response_body = [body_modified]
      elsif !target_response_body.empty?
        modify_response_headers(response_headers, matcher)
        body_modified = modify_response_body(target_response_body, matcher)
        response_headers.delete('content-length')
        response_body = [body_modified]
      else
        response_body = []
      end
      [target_response.status, response_headers, response_body]
    end

    def extract_http_request_headers(env)
      headers = env.reject do |k, v|
        !(/^HTTP_[A-Z_]+$/ === k) || v.nil?
      end.map do |k, v|
        [reconstruct_header_name(k), v]
      end.inject(Utils::HeaderHash.new) do |hash, k_v|
        k, v = k_v
        hash[k] = v
        hash
      end

      x_forwarded_for = (headers["X-Forwarded-For"].to_s.split(/, +/) << env["REMOTE_ADDR"]).join(", ")

      headers.merge!("X-Forwarded-For" =>  x_forwarded_for)
    end

    def reconstruct_header_name(name)
      name.sub(/^HTTP_/, "").gsub("_", "-")
    end

    def get_matcher(path, headers, rackreq)
      matches = @matchers.select do |matcher|
        matcher.match?(path, headers, rackreq)
      end

      if matches.length < 1
        nil
      elsif matches.length > 1 && @global_options[:matching] != :first
        raise AmbiguousProxyMatch.new(path, matches)
      else
        matches.first
      end
    end

    def reverse_proxy_options(options)
      @global_options=options
    end

    def reverse_proxy(matcher, url=nil, opts={})
      raise GenericProxyURI.new(url) if matcher.is_a?(String) && url.is_a?(String) && URI(url).class == URI::Generic
      @matchers << ReverseProxyMatcher.new(matcher,url,opts)
    end

    def modify_request_headers(headers)
      # should be overrided
    end

    def modify_response_headers(response_headers)
      # should be overrided
    end

    def modify_response_body(body)
      # should be overrided
      body
    end
  end
end

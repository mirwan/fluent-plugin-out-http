class Fluent::HTTPOutput < Fluent::Output
  Fluent::Plugin.register_output('http', self)

  def initialize
    super
    require 'net/http/persistent'
    require 'uri'
    require 'yajl'
  end

  # Endpoint URL ex. localhost.local/api/
  config_param :endpoint_url, :string

  # Endpoint URL ex. localhost.local/api/
  config_param :remove_prefix, :string, :default => nil

  # HTTP method
  config_param :http_method, :string, :default => :post
  
  # form | json
  config_param :serializer, :string, :default => :form

  # Simple rate limiting: ignore any records within `rate_limit_msec`
  # since the last one.
  config_param :rate_limit_msec, :integer, :default => 0

  # Raise errors that were rescued during HTTP requests?
  config_param :raise_on_error, :bool, :default => true

  # nil | 'none' | 'basic'
  config_param :authentication, :string, :default => nil 
  config_param :username, :string, :default => ''
  config_param :password, :string, :default => '', :secret => true

  def configure(conf)
    super

    serializers = [:json, :form]
    @serializer = if serializers.include? @serializer.intern
                    @serializer.intern
                  else
                    :form
                  end

    http_methods = [:get, :put, :post, :delete]
    @http_method = if http_methods.include? @http_method.intern
                    @http_method.intern
                  else
                    :post
                  end

    @auth = case @authentication
            when 'basic' then :basic
            else
              :none
            end

    if @remove_prefix
       @remove_prefix_string = @remove_prefix + '.'
       @remove_prefix_length = @remove_prefix_string.length
    end
  end

  def start
    super
    @pers = Net::HTTP::Persistent.new()
  end

  def shutdown
    super
  end

  def format_url(tag, time, record)
    if tag == @remove_prefix or @remove_prefix and (tag[0, @remove_prefix_length] == @remove_prefix_string and tag.length > @remove_prefix_length)
	tag = tag[@remove_prefix_length..-1]
    end
    "%s?tag=%s&timestamp=%s" % [@endpoint_url, tag, time]
  end

  def set_body(req, tag, time, record)
    if @serializer == :json
      set_json_body(req, record)
    else
      req.set_form_data(record)
    end
    req
  end

  def set_header(req, tag, time, record)
    req
  end

  def set_json_body(req, data)
    req.body = Yajl.dump(data)
    req['Content-Type'] = 'application/json'
  end

  def create_request(tag, time, record)
    url = format_url(tag, time, record)
    uri = URI.parse(url)
    req = Net::HTTP.const_get(@http_method.to_s.capitalize).new(uri.path + "?" + uri.query)
    set_body(req, tag, time, record)
    set_header(req, tag, time, record)
    return req, uri
  end

  def send_request(req, uri)    
    is_rate_limited = (@rate_limit_msec != 0 and not @last_request_time.nil?)
    if is_rate_limited and ((Time.now.to_f - @last_request_time) * 1000.0 < @rate_limit_msec)
      $log.info('Dropped request due to rate limiting')
      return
    end
    
    res = nil

    begin
      if @auth and @auth == :basic
        req.basic_auth(@username, @password)
      end
      @last_request_time = Time.now.to_f
      res = @pers.request(uri,req)
    rescue => e # rescue all StandardErrors
      # server didn't respond
      $log.warn "Exception: #{e.to_s}"
      raise e if @raise_on_error
    else
       unless res and res.is_a?(Net::HTTPSuccess)
          res_summary = if res
                           "#{res.code} #{res.message} #{res.body}"
                        else
                           "res=nil"
                        end
          $log.warn "failed to #{req.method} #{uri} (#{res_summary})"
       end #end unless
    end # end begin
  end # end send_request

  def handle_record(tag, time, record)
    req, uri = create_request(tag, time, record)
    send_request(req, uri)
  end

  def emit(tag, es, chain)
    es.each do |time, record|
      handle_record(tag, time, record)
    end
    chain.next
  end
end

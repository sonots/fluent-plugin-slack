require_relative 'slack_client'

module Fluent
  class SlackOutput < Fluent::BufferedOutput
    Fluent::Plugin.register_output('buffered_slack', self) # old version compatiblity
    Fluent::Plugin.register_output('slack', self)

    include SetTimeKeyMixin
    include SetTagKeyMixin

    config_set_default :include_time_key, true
    config_set_default :include_tag_key, true
   
    config_param :webhook_url,          :string, default: nil # incoming webhook
    config_param :token,                :string, default: nil # api token
    config_param :username,             :string, default: 'fluentd'
    config_param :icon_emoji,           :string, default: nil
    config_param :icon_url,             :string, default: nil
    config_param :auto_channels_create, :bool,   default: false
    config_param :https_proxy,          :string, default: nil

    config_param :color,                :string, default: 'good'
    config_param :color_keys,           default: nil do |val|
      val.split(',')
    end
    config_param :channel,              :string
    config_param :channel_keys,         default: nil do |val|
      val.split(',')
    end
    config_param :title,                :string, default: nil
    config_param :title_keys,           default: nil do |val|
      val.split(',')
    end
    config_param :message,              :string, default: nil
    config_param :message_keys,         default: nil do |val|
      val.split(',')
    end

    # for test
    attr_reader :slack, :time_format, :localtime, :timef

    def initialize
      super
      require 'uri'
    end

    def configure(conf)
      conf['time_format'] ||= '%H:%M:%S' # old version compatiblity
      conf['localtime'] ||= true unless conf['utc']
 
      super

      @channel = URI.unescape(@channel) # old version compatibility
      @channel = '#' + @channel unless @channel.start_with?('#')

      if @webhook_url
        if @webhook_url.empty?
          raise Fluent::ConfigError.new("`webhook_url` is an empty string")
        end
        # following default values are for old version compatibility
        @title         ||= '%s'
        @title_keys    ||= %w[tag]
        @message       ||= '[%s] %s'
        @message_keys  ||= %w[time message]
        @slack = Fluent::SlackClient::IncomingWebhook.new(@webhook_url)
      elsif @token
        if @token.empty?
          raise Fluent::ConfigError.new("`token` is an empty string")
        end
        @message      ||= '%s'
        @message_keys ||= %w[message]
        @slack = Fluent::SlackClient::WebApi.new
      else
        raise Fluent::ConfigError.new("Either of `webhook_url` or `token` is required")
      end
      @slack.log = log
      @slack.debug_dev = log.out if log.level <= Fluent::Log::LEVEL_TRACE

      if @https_proxy
        @slack.https_proxy = @https_proxy
      end

      begin
        @message % (['1'] * @message_keys.length)
      rescue ArgumentError
        raise Fluent::ConfigError, "string specifier '%s' for `message`  and `message_keys` specification mismatch"
      end
      if @title and @title_keys
        begin
          @title % (['1'] * @title_keys.length)
        rescue ArgumentError
          raise Fluent::ConfigError, "string specifier '%s' for `title` and `title_keys` specification mismatch"
        end
      end
      if @channel_keys
        begin
          @channel % (['1'] * @channel_keys.length)
        rescue ArgumentError
          raise Fluent::ConfigError, "string specifier '%s' for `channel` and `channel_keys` specification mismatch"
        end
      end
      if @color_keys
        begin
          @color % (['1'] * @color_keys.length)
        rescue ArgumentError
          raise Fluent::ConfigError, "string specifier '%s' for `color` and `color_keys` specification mismatch"
        end
      end

      if @icon_emoji and @icon_url
        raise Fluent::ConfigError, "either of `icon_emoji` or `icon_url` can be specified"
      end
      @icon_emoji ||= ':question:' unless @icon_url

      @post_message_opts = @auto_channels_create ? {auto_channels_create: true} : {}
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      begin
        payloads = build_payloads(chunk)
        payloads.each {|payload| @slack.post_message(payload, @post_message_opts) }
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        log.warn "out_slack:", :error => e.to_s, :error_class => e.class.to_s
        raise e # let Fluentd retry
      rescue => e
        log.error "out_slack:", :error => e.to_s, :error_class => e.class.to_s
        log.warn_backtrace e.backtrace
        # discard. @todo: add more retriable errors
      end
    end

    private

    def build_payloads(chunk)
      if @title
        build_title_payloads(chunk)
      else
        build_plain_payloads(chunk)
      end
    end

    def common_payload
      return @common_payload if @common_payload
      @common_payload = {}
      @common_payload[:username]   = @username
      @common_payload[:icon_emoji] = @icon_emoji if @icon_emoji
      @common_payload[:icon_url]   = @icon_url   if @icon_url
      @common_payload[:token]      = @token      if @token
      @common_payload
    end

    Field = Struct.new("Field", :title, :value)

    def build_title_payloads(chunk)
      ch_fields = {}
      chunk.msgpack_each do |tag, time, record|
        channel = build_channel(record)
        color   = build_color(record)
        per     = tag # title per tag
        ch_fields[channel]             ||= {}
        ch_fields[channel][color]      ||= {}
        ch_fields[channel][color][per] ||= Field.new(build_title(record), '')
        ch_fields[channel][color][per].value << "#{build_message(record)}\n"
      end
      ch_fields.map do |channel, color_fields|
        attachments = color_fields.map do |color, fields|
          {
            :color    => color,
            :fallback => fields.values.map(&:title).join(' '), # fallback is the message shown on popup
            :fields   => fields.values.map(&:to_h),
          }
        end
        {
          channel: channel,
          attachments: attachments,
        }.merge(common_payload)
      end
    end

    def build_plain_payloads(chunk)
      messages = {}
      chunk.msgpack_each do |tag, time, record|
        channel = build_channel(record)
        color   = build_color(record)
        messages[channel]        ||= {}
        messages[channel][color] ||= ''
        messages[channel][color] << "#{build_message(record)}\n"
      end
      messages.map do |channel, color_text|
        attachments = color_text.map do |color, text|
          {
            :color    => color,
            :fallback => text,
            :text     => text,
          }
        end
        {
          channel: channel,
          attachments: attachments,
        }.merge(common_payload)
      end
    end

    def build_message(record)
      values = fetch_keys(record, @message_keys)
      @message % values
    end

    def build_title(record)
      return @title unless @title_keys

      values = fetch_keys(record, @title_keys)
      @title % values
    end

    def build_channel(record)
      return @channel unless @channel_keys

      values = fetch_keys(record, @channel_keys)
      @channel % values
    end

    def build_color(record)
      return @color unless @color_keys

      values = fetch_keys(record, @color_keys)
      @color % values
    end

    def fetch_keys(record, keys)
      Array(keys).map do |key|
        begin
          record.fetch(key).to_s
        rescue KeyError
          log.warn "out_slack: the specified key '#{key}' not found in record. [#{record}]"
          ''
        end
      end
    end
  end
end

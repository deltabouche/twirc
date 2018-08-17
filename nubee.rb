require 'dotenv/load'
require "./irc_server"
require "twitter"
require 'oauth'
require 'digest'
require 'htmlentities'
require "./blowfish"
require 'loofah'
require 'rails'
require 'net/http'
require 'json'
require 'uri'
require 'andand'

TWITTER_CLIENT_ID = ENV['TWITTER_CLIENT_ID']
TWITTER_CLIENT_SECRET = ENV['TWITTER_CLIENT_SECRET']

ID_BASE = 36
ID_DIGITS = 3

SALT1 = ENV['SALT1']
SALT2 = ENV['SALT2']
SALT3 = ENV['SALT3']
SALT4 = ENV['SALT4']

BF_KEY = ENV['BF_KEY']

CACHE_SIZE = ID_BASE ** ID_DIGITS

SEARCH_REFRESH_TIME = 60

BACKLOG_FETCH_SIZE = 20

class CacheEntry
  attr_reader :id, :client
  def initialize client, twitter_id, obj=nil
    @client = client
    @id = twitter_id
    @tweet = obj
  end
  def tweet
    @tweet ||= client.status(id, tweet_mode: 'extended')
  end
  def reload
    @tweet = client.status(id, tweet_mode: 'extended')
  end
end

def cache_id_display(cache_id)
  cache_id.to_s(ID_BASE).upcase.rjust(ID_DIGITS, '0')
end

def encrypt_pass(password)
  s = Digest::MD5.hexdigest("#{SALT1}#{password}#{SALT2}")
  Digest::MD5.hexdigest("#{SALT3}#{s}#{SALT4}")
end

class CommandHandler
  attr_accessor :command, :block
  def initialize command, &block
    @command = command
    @block = block
  end
end

class ServiceCommandHandler
  attr_accessor :service, :command, :block
  def initialize service, command, &block
    @service = service
    @command = command
    @block = block
  end
end

class PMCommandHandler
  attr_accessor :command, :block
  def initialize command, &block
    @command = command
    @block = block
  end
end

class BaseController
  attr_accessor :owner
  def initialize owner
    @command_handlers = []
    @irc_command_handlers = []
    @serv_command_handlers = []
    @pm_command_handlers = []
    @owner = owner
  end
  def handler_command *command, &block
    command.each do |c|
      @command_handlers << CommandHandler.new(c, &block)
    end
  end
  def handler_irc_command *command, &block
    command.each do |c|
      @irc_command_handlers << CommandHandler.new(c, &block)
    end
  end
  def handler_serv_command service, *command, &block
    command.each do |c|
      @serv_command_handlers << ServiceCommandHandler.new(service, c, &block)
    end
  end
  def handler_pm_command *command, &block
    command.each do |c|
      @pm_command_handlers << PMCommandHandler.new(c, &block)
    end
  end
  def handle_command command, args
    @command_handlers.select{|handler| handler.command.downcase == command.downcase}.each {|handler| handler.block.call(owner, args)}
  end
  def handle_irc_command command, prefix, params
    @irc_command_handlers.select{|handler| handler.command.downcase == command.downcase}.each {|handler| handler.block.call(owner, prefix, params)}
  end
  def handle_serv_command command, service, args
    @serv_command_handlers.select{|handler| handler.command.downcase == command.downcase && handler.service.downcase == service.downcase}.each {|handler| handler.block.call(owner, args)}
  end
  def handle_pm_command command, target, args
    @pm_command_handlers.select{|handler| handler.command.downcase == command.downcase }.each {|handler| handler.block.call(owner, target, args)}
  end
  def assign_handlers
  end
end

class TwitterUser < VirtualUser
  attr_accessor :twitter_user
  def initialize user
    @nick = user.screen_name
    @username = user.screen_name.downcase
    @hostname = "twitter.com"
    @real_name = user.name
    @twitter_user = user
  end
end

class TwitterController < BaseController

  def get_cursor_text_from_tweet tweet, cursor_value = nil
    reply_hex = nil
    if tweet.reply?
      parent_id = get_cache_id_by_status_id_lazy tweet.in_reply_to_status_id
      reply_hex = cache_id_display parent_id
    end
    cursor_hex = ""
    if cursor_value.nil?
      this_tweet = get_tweet_from_cache tweet.id
      cursor_value = get_cache_id_by_status_id_lazy tweet.id if this_tweet
    end
    cursor_hex = cache_id_display cursor_value unless cursor_value.nil?
    cursor_hex = "#{cursor_hex} → #{reply_hex}" if reply_hex
    cursor_hex
  end

  def this_user
    @this_user ||= @rest_client.user
  end

  def time_zone
    this_user.time_zone
  end

  def fmt_time t, tz=nil
    tz = time_zone if tz.nil?
    if tz.nil?
      t.in_time_zone('UTC').to_s.split(" ")[0..1].join(" ")
    else
      t.in_time_zone(tz).to_s.split(" ")[0..1].join(" ")
    end
  end

  def get_preferred_recipient_from_tweet tweet
    if tweet.in_reply_to_status_id
      if tweet.user.screen_name.downcase == owner.nick.downcase
        parent_tweet = get_tweet_from_cache tweet.in_reply_to_status_id
        if parent_tweet
          return get_preferred_recipient_from_tweet parent_tweet
        end
        # keep going, don't treat as a reply
      else
        return tweet.user.screen_name
      end
    end

    if tweet.user.screen_name.downcase == owner.nick.downcase
      candidates = tweet.user_mentions.map { |u| u.screen_name }.select { |m| m.downcase != owner.nick.downcase }
      if candidates.size  == 0
        return nil #REPLYING TO YOURSELF!
      else
        return candidates.first
      end
    else
      return tweet.user.screen_name
    end
  end

  def get_user_pair_from_dm dm
    sender_user = get_twitter_user_by_screen_name dm.sender.screen_name
    unless sender_user
      sender_user = TwitterUser.new(dm.sender)
      @twitter_users << sender_user
    end
    recipient_user = get_twitter_user_by_screen_name dm.recipient.screen_name
    unless sender_user
      recipient_user = TwitterUser.new(dm.recipient)
      @twitter_users << recipient_user
    end

    [sender_user, recipient_user]
  end

  def get_twitter_user_by_screen_name_2
    twitter_user = get_twitter_user_by_screen_name username.downcase
    return twitter_user if twitter_user
    user = @rest_client.user(username)
    twitter_user = TwitterUser.new(user)
    @twitter_users << twitter_user
    twitter_user
  end

  def get_twitter_user_from_tweet tweet
    twitter_user = get_twitter_user_by_screen_name tweet.user.screen_name
    unless twitter_user
      twitter_user = TwitterUser.new(tweet.user)
      @twitter_users << twitter_user
    end
    twitter_user
  end

  def get_twitter_user_from_user_object user
    twitter_user = get_twitter_user_by_screen_name user.screen_name
    unless twitter_user
      twitter_user = TwitterUser.new(user)
      @twitter_users << twitter_user
    end
    twitter_user
  end

  def get_tweet_from_cache status_id, reload=false
    twt = @tweet_cache.detect do |tw|
      tw.id == status_id if tw
    end
    if twt
      twt.reload if reload
      twt.tweet
    else
      nil
    end
  end

  def get_tweet_by_cache_id cache_id, reload=false
    twt = @tweet_cache[cache_id]
    if twt
      twt.reload if reload
      twt.tweet
    else
      nil
    end
  end

  def get_tweet cid
    @tweet_cache[convert_cache_id(cid)].andand.tweet
  end

  def get_cache_id_and_entry tweet
    entry = @tweet_cache.detect do |tw|
      tw.id == tweet.id if tw
    end
    unless entry
      entry = CacheEntry.new @rest_client, tweet.id, tweet
      @tweet_cache[@cursor] = entry
      increment_cursor
    end
    [@tweet_cache.index(entry), entry.tweet]
  end

  def get_cache_id_by_status_id_lazy status_id
    entry = @tweet_cache.detect do |tw|
      tw.id == status_id if tw
    end
    unless entry
      entry = CacheEntry.new @rest_client, status_id
      @tweet_cache[@cursor] = entry
      increment_cursor
    end
    @tweet_cache.index(entry)
  end


  def get_dm_cache_id_and_entry dm
    fdm = @dm_cache.detect do |d|
      d.id == dm.id if d
    end
    unless fdm
      fdm = dm
      @dm_cache[@dm_cursor] = dm
      increment_dm_cursor
    end
    [@dm_cache.index(fdm), fdm]
  end


  def convert_cache_id a
    a = a.strip
    r = a.to_i(ID_BASE) rescue 0
    raise "#{a} is not a valid ID" if r == 0
    r
  end

  def get_instagram_info url
    urlstr = url.to_s
    if urlstr.start_with?("http://instagram.com/p/") || urlstr.start_with?("https://instagram.com/p/")
      uri = URI.parse("http://api.instagram.com/oembed?url=#{urlstr}")
      res = JSON.parse(Net::HTTP.get(uri)) rescue nil
      return nil if res.nil?
      img_url = res['url']
      title = res['title']
      type = res['type']
      if img_url.nil?
        nil
      else
        "[ Instagram: #{img_url} ] #{title}"
      end
    else
      nil
    end
  end

  def render_dm show_timestamp, dm
    acid, ndm = get_dm_cache_id_and_entry dm
    cursor_hex = cache_id_display acid

    sender, recipient = get_user_pair_from_dm dm


    if sender.nick.downcase == owner.nick.downcase
      targ = recipient
      prefix = "[← #{cursor_hex}]"
    else
      targ = sender
      prefix = "[→ #{cursor_hex}]"
    end



    text = @htmlentities.decode dm.text

    if dm.media
      if dm.media.size > 0
        text += "\n[ Attach: " + dm.media.map{|t| t.media_uri }.join(" ") + " ]"
      end
    end

    text = expand_and_extract_urls(dm, text)

    mtext = text.split "\n"

    prefix = "[#{fmt_time(dm.created_at)}] #{prefix}" if show_timestamp


    if mtext.size == 1
      owner.msg targ, "#{prefix} #{text}"
    else
      owner.msg targ, "#{prefix}:"
      mtext.each do |t|
        owner.msg targ, t
      end
    end


  end

  def expand_and_extract_urls(obj, text)
    if obj.uris
      if obj.uris.size > 0
        obj.uris.each do |u|
          if u.expanded_url.nil?
            inf = get_instagram_info u.url
          else
            inf = get_instagram_info u.expanded_url
          end

          unless inf.nil?
            text += "\n" + inf
          end

          text = text.gsub(u.url.to_s, u.expanded_url.to_s)
        end
      end
    end
    text
  end

  def render_tweet show_timestamp, channel, user, prefix, tweet, action=false, show_muted=false
    muted = !show_muted && (
      @mute_list.include?(user.twitter_user.id) ||
      @mute_list.include?(tweet.user.id)
    ) rescue false
    prefix = "[#{fmt_time(tweet.created_at)}] #{prefix}" if show_timestamp

    if !muted
      text = @htmlentities.decode tweet.to_h[:full_text]
      raw_tweet = tweet.to_h
      if raw_tweet[:extended_entities]
        if raw_tweet[:extended_entities][:media].size > 0
          text += "\n[ Attach: " + raw_tweet[:extended_entities][:media].map{|t| t[:media_url] }.join(" ") + " ]"

          videos = raw_tweet[:extended_entities][:media].map {|t| t[:video_info].andand[:variants].andand.first.andand[:url] }.compact

          if videos.size > 0
            text += "\n[ Video: " + videos.join(" ") + " ]"
          end

          raw_tweet[:extended_entities][:media].each do |t|
            text = text.gsub(t[:url],"")
          end
        end
      end

      text = expand_and_extract_urls(tweet, text)

      mtext = text.split "\n"
      if mtext.size == 1
        channel.msg user, "#{prefix} #{text}" unless action
        channel.action user, "#{prefix} #{text}" if action
      else
        channel.msg user, "#{prefix}:" unless action
        channel.action user, "#{prefix}:" if action
        mtext.each do |t|
          channel.msg user, t
        end
      end
    else
      channel.msg user, "#{prefix} [hidden]" unless action
      channel.action user, "#{prefix} [hidden]" if action
    end
  end

  def increment_cursor
    @cursor = (@cursor + 1) % CACHE_SIZE
    @cursor = 1 if @cursor == 0
  end

  def increment_dm_cursor
    @dm_cursor = (@dm_cursor + 1) % CACHE_SIZE
    @dm_cursor = 1 if @dm_cursor == 0
  end

  def get_mute_list reload=false
    reload_parse_user if reload
    pml = @parse_user['mute_list']
    if pml.nil? || pml.to_s.strip.size == ""
      @mute_list = []
      save_mute_list
    else
      @mute_list = pml
    end

  end

  def add_to_mute_list user_id
    get_mute_list true
    if @mute_list.include?(user_id)
      raise "User is already muted."
    else
      @mute_list << user_id
      save_mute_list
    end
  end

  def remove_from_mute_list user_id
    get_mute_list true
    if @mute_list.include?(user_id)
      @mute_list.delete(user_id)
      save_mute_list
    else
      raise "User was not muted in the first place."
    end
  end

  def liked_word
    (@prefs['like_text'] && @prefs['like_text'][0]) || 'liked'
  end

  def unliked_word
    (@prefs['like_text'] && @prefs['like_text'][1]) || 'unliked'
  end

  def get_prefs reload=false
    reload_parse_user if reload
    prf = @parse_user['prefs']
    if prf.nil?
      @prefs = { "hide_follow" => false }
      save_prefs
    else
      @prefs = prf
    end
  end

  def save_prefs
    @parse_user['prefs'] = @prefs
    save_parse_user
  end

  def update_prefs &block
    get_prefs true
    block.call @prefs
    save_prefs
  end

  def save_mute_list
    @parse_user['mute_list'] = @mute_list
    save_parse_user
  end

  def save_parse_user
    save_parse_user_file @parse_username
  end

  def save_parse_user_file username, user: nil
    user ||= @parse_user
    File.open("data/#{username}.token", "wb") do |f|
      f.write(JSON.pretty_generate(user))
    end
  end

  def reload_parse_user
    @parse_user = load_parse_user owner.nick.downcase
    @parse_username = owner.nick.downcase
  end

  def load_parse_user username
    return nil unless File.exist?("data/#{username}.token")
    File.open("data/#{username}.token", "rb") { |f| JSON.parse(f.read) } rescue nil
  end

  def after_login parse_user, parse_username
    @rest_client = Twitter::REST::Client.new do |config|
      configure_client(config, parse_user)
    end
    # @stream_client = Twitter::Streaming::Client.new do |config|
    #   configure_client(config, parse_user)
    # end

    @parse_user = parse_user
    @parse_username = parse_username
    get_mute_list
    get_prefs
    owner.serv_notice "NickServ", "You are now logged in!"
    owner.control_msg "Welcome!"
    @logged_in = true
    @oauth_step = 0

    start_streaming_channel
  end

  def configure_client(config, parse_user)
    config.consumer_key        = TWITTER_CLIENT_ID
    config.consumer_secret     = TWITTER_CLIENT_SECRET
    config.access_token        = Blowfish.decrypt(BF_KEY, parse_user["authToken"])
    config.access_token_secret = Blowfish.decrypt(BF_KEY, parse_user["authSecret"])
  end

  def process_event owner, channel, object, show_timestamp = false, show_muted = false, refetch: false
    event_name, entity = object
    
    entity = @rest_client.status(entity.id, tweet_mode: 'extended') if refetch

    case event_name
    when :delete
      twitter_user = get_twitter_user_from_tweet entity
      cursor_text = get_cursor_text_from_tweet entity
      render_tweet_standard(channel, cursor_text, show_timestamp, entity, twitter_user, "deleted ", true, show_muted)
    when :favorite
      cid, parent_tweet = get_cache_id_and_entry entity
      twitter_user = get_twitter_user_from_tweet parent_tweet
      source_user = get_twitter_user_by_screen_name_2 parent_tweet.source
      cursor_text = get_cursor_text_from_tweet parent_tweet, cid
      render_tweet show_timestamp, channel, source_user, "#{liked_word} [#{twitter_user.nick} #{cursor_text}]", parent_tweet, true, show_muted
    when :unfavorite
      cid, parent_tweet = get_cache_id_and_entry entity
      twitter_user = get_twitter_user_from_tweet parent_tweet
      source_user = get_twitter_user_by_screen_name_2 parent_tweet.source
      cursor_text = get_cursor_text_from_tweet parent_tweet, cid
      render_tweet show_timestamp, channel, source_user, "#{unliked_word} [#{twitter_user.nick} #{cursor_text}]", parent_tweet, true, show_muted
    when :follow
      follower = get_twitter_user_from_user_object this_user
      target = get_twitter_user_from_user_object entity

      if follower.nick.downcase == owner.nick.downcase
        chuser = channel.join_user target
        channel.set_mode_to_user owner.control_user, chuser, ["h"] if target.twitter_user.protected?
        channel.set_mode_to_user owner.control_user, chuser, ["v"] if @followers.include?(target.twitter_user.id)
      else
        chuser = channel.user_for_user follower
        @followers << follower.twitter_user.id if !@followers.include?(follower.twitter_user.id)
        channel.set_mode_to_user owner.control_user, chuser, ["v"] if channel.users.include?(follower)
      end

      channel.action follower, "is now following #{target.nick}" if !@prefs["hide_follow"] || follower.nick.downcase == owner.nick.downcase
    when :unfollow
      follower = get_twitter_user_from_user_object this_user
      target = get_twitter_user_from_user_object entity

      channel.action follower, "stopped following #{target.nick}"

      if follower.nick.downcase == owner.nick.downcase
        channel.kick_user owner.control_user, target, "Get outta here!"
      else
        chuser = channel.user_for_user follower
        @followers.delete(follower.twitter_user.id) if @followers.include?(follower.twitter_user.id)
        channel.set_mode_to_user owner.control_user, chuser, [], ["v"] if chuser
      end
    when :quote_tweet
      render_tweet_quick channel, entity, show_timestamp, show_muted
    when :tweet
      render_tweet_quick channel, entity, show_timestamp, show_muted
    end
  end

  def render_tweet_quick(channel, object, show_timestamp = true, show_muted = false)
    twitter_user = get_twitter_user_from_tweet object
    acid, tweet  = get_cache_id_and_entry object
    cursor_text  = get_cursor_text_from_tweet tweet, acid
    render_tweet_standard(channel, cursor_text, show_timestamp, tweet, twitter_user, "", false, show_muted)
  end

  def render_tweet_standard(channel, cursor_text, show_timestamp, tweet, twitter_user, prefix = "", action = false, show_muted = false)
    if tweet.retweet?
      retweeted_user        = get_twitter_user_from_tweet tweet.retweeted_status
      cid, retweeted_tweet  = get_cache_id_and_entry tweet.retweeted_status
      retweeted_cursor_text = get_cursor_text_from_tweet retweeted_tweet, cid
      render_tweet show_timestamp, channel, twitter_user, "#{prefix}[#{cursor_text} RT #{retweeted_user.nick} #{retweeted_cursor_text}]", retweeted_tweet, action, show_muted
    else
      render_tweet show_timestamp, channel, twitter_user, "#{prefix}[#{cursor_text}]", tweet, action, show_muted
    end
  end

  def post_update(channel, text, mentions = nil, opts = {})
    text = text.strip
    prefix = opts[:prefix] || ""
    @last_transact = []
    if mentions.nil? #see if first token is a mention
      tokens = text.split(/(@\w+)/).map{|x| x.strip}.select { |x| x.size > 0 }
      mention_list = []
      tokens.each { |t| break unless t.start_with?("@") ; mention_list << t }
      if mention_list.size > 0
        mentions = mention_list.join(" ").strip
        text = text.partition(mentions).last.strip #separate the mention from the text
      end
    end
    @last_id = nil
    @last_mens = mentions
    @last_prefix = prefix
    multi_delimiter = "./."

    text.split(multi_delimiter).each do |part|
      part = "#{mentions.strip} #{part.strip}" unless mentions.nil?
      opts = opts.merge(in_reply_to_status_id: @last_id) unless @last_id.nil?

      new_tweet = @rest_client.update!(prefix + part, opts)

      if new_tweet
        @last_id = new_tweet.id
        @last_transact << ['update', new_tweet.id]

        process_event owner, channel, [:tweet, new_tweet], refetch: true
      else
        raise "Unable to post tweet #{final_text.split("\n").first}"
      end

    end
  end

  class ShouldDieError < StandardError; end

  def dputs msg, prefix=""
    msg.split("\n").each do |m|
      @xchannel.msg owner.control_user, prefix + m
    end
  end

  def print_error channel, e, prefix
    channel.msg owner.control_user, "#{prefix} #{e.class.name}: #{e.message}"
    e.backtrace.each do |bt|
      channel.msg owner.control_user, "--> #{bt}"
    end
  end

  def start_thread channel, the_first=true
    @thread = Thread.new do
      first = the_first
      begin
        populate_followers(channel)
        while true
          begin
            after_stream_connect(channel, first)
            first = false
          rescue => e
            print_error channel, e, "MASSIVE ERROR!"
          end
          sleep 75
        end
      rescue => e
        print_error channel, e, "CONNECT ERROR!"
      end
    end
  end

  def populate_followers(channel)
    begin
      followers = @rest_client.follower_ids
      followers.each do |f|
        @followers << f if !@followers.include?(f)
      end
    rescue => e
      #can't retrieve followers for now.. oh well!
    end
    friend_ids = @rest_client.friend_ids
    friends = @rest_client.users(friend_ids.to_a)
    friends.each do |f|
      twitter_user = get_twitter_user_by_screen_name f.screen_name
      puts "#{f.screen_name}"

      unless twitter_user
        puts "Adding new user"
        twitter_user = TwitterUser.new(f)
        @twitter_users << twitter_user
      end

      modes = []
      modes << "h" if twitter_user.twitter_user.protected?
      modes << "v" if @followers.include?(f.id)

      channel.add_user twitter_user, modes
    end
  end

  def after_stream_connect(channel, first)

    if first
      channel.join_owner owner
      channel.msg owner.control_user, "Welcome back! Fetching your backlog..."
      timeline = @rest_client.home_timeline(count: BACKLOG_FETCH_SIZE, tweet_mode: 'extended') + @rest_client.mentions_timeline(count: BACKLOG_FETCH_SIZE, tweet_mode: 'extended') + @rest_client.retweets_of_me(count: BACKLOG_FETCH_SIZE, tweet_mode: 'extended')
      timeline = timeline.uniq.compact.sort { |a, b| a.created_at <=> b.created_at }
      timeline.each do |obj|
        process_event owner, channel, [:tweet, obj], true
        @last_received_tweet_id = obj.id if obj.id
      end
      channel.msg owner.control_user, "-End of Backlog-"
      first = false
    else
      # channel.msg owner.control_user, "Fetching gap"
      if @last_received_tweet_id
        timeline = @rest_client.home_timeline(count: 200, since_id: @last_received_tweet_id, tweet_mode: 'extended') + @rest_client.mentions_timeline(count: 200, since_id: @last_received_tweet_id, tweet_mode: 'extended') + @rest_client.retweets_of_me(count: 100, since_id: @last_received_tweet_id, tweet_mode: 'extended')
      else
        timeline = @rest_client.home_timeline(count: 200, tweet_mode: 'extended') + @rest_client.mentions_timeline(count: 200, tweet_mode: 'extended') + @rest_client.retweets_of_me(count: 100, tweet_mode: 'extended')
      end
      timeline = timeline.uniq.compact.sort { |a, b| a.created_at <=> b.created_at }
      timeline.each do |obj|
        process_event owner, channel, [:tweet, obj], true
        @last_received_tweet_id = obj.id if obj.id
      end
      # channel.msg owner.control_user, "-End of gap-"

      # channel.msg owner.control_user, "Stream reconnected."
    end
  end

  def create_search_channel name, query
    owner.create_channel name, "Search: #{query}" do |channel|
      @search_channels << channel

      channel.join_owner owner
      channel.msg owner.control_user, "Fetching search, refresh time is #{SEARCH_REFRESH_TIME} seconds..."

      @search_threads << Thread.new do
        begin
          last_result_id = 0
          while 1
            opts = {count: 200}
            opts[:since_id] = last_result_id if last_result_id > 0
            results = @rest_client.search(query, opts).each {}.to_a.sort { |a,b| a.id <=> b.id }
            results.each { |t| render_tweet_quick channel, t }
            if results.size > 0
              last_result_id = results.last.id
            end
            sleep SEARCH_REFRESH_TIME
          end
        rescue => e
          print_error channel, e, "BIG FAIL!!!"
        end
      end
    end
  end

  def start_streaming_channel
    owner.create_channel '#timeline', 'Twitter Timeline' do |channel|
      @streaming_channel = channel
      @multiline = false
      @search_channels = []
      @search_threads = []
      @multibuf = []
      @last_mens = nil
      @last_id = nil
      @last_transact = []
      @last_received_tweet_id = nil
      @thread = nil


      start_thread channel, true

      cmd_help = ["<code>", "Evaluate a Ruby expression", true]
      channel.on_command cmd_help, "eval" do |c, owner, args|
        @xchannel = channel
        begin
          dputs instance_eval(args, "rubby", 1).inspect, " => "
        rescue SyntaxError => e
          dputs e.inspect, " SYNTAX ERROR: "
        rescue => e
          dputs e.inspect, " EXCEPTION: "
        end
      end

      cmd_help = ["<text>", "Post a tweet", false]
      channel.on_command cmd_help, "post", "p" do |c, owner, args|
        if args.strip.size == 0
          raise "You didn't enter any text!"
        else
          post_update channel, args
        end
      end

      cmd_help = ["<text>", "Post a tweet with a . prefix", true]
      channel.on_command cmd_help, "ppost", "pp" do |c, owner, args|
        if args.strip.size == 0
          raise "You didn't enter any text!"
        else
          post_update channel, args, nil, prefix: "."
        end
      end

      cmd_help = ["<text>", "Extend (reply to your) last tweet", false]
      channel.on_command cmd_help, "ext", "x" do |c, owner, args|
        if args.strip.size == 0
          raise "You didn't enter any text!"
        else
          if @last_id.nil?
            raise "No tweet to extend!"
          else
            post_update channel, args, @last_mens, in_reply_to_status_id: @last_id, prefix: @last_prefix
          end
        end
      end

      cmd_help = ["<id or url>[, <id or url> ...]", "Retweet tweet(s)", false]
      channel.on_command cmd_help, "rt" do |c, owner, args|
        args.split(" ").each do |i|
          begin
            @last_transact = []
            cache_id, tweet = extract_cache_id_from_number_or_url i
            if tweet
              rts = @rest_client.retweet(tweet.id)
              rts.each do |rt|
                @last_transact << ['rt', rt.id]
                process_event owner, channel, [:tweet, rt], refetch: true
              end
            else
              raise "Tweet #{cache_id_display cache_id} doesn't exist"
            end
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end

      cmd_help = ["<id or url>[, <id or url> ...]", "Delete tweet(s)", false]
      channel.on_command cmd_help, "dl", "rm" do |c, owner, args|
        args.split(" ").each do |i|
          begin
            cache_id, tweet = extract_cache_id_from_number_or_url i
            if tweet
              @rest_client.destroy_status(tweet.id)
              process_event owner, channel, [:delete, tweet], true
            else
              raise "Tweet #{cache_id_display cache_id} doesn't exist"
            end
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end

      cmd_help = ["<id or url>[, <id or url> ...]", "Display tweet(s)", false]
      channel.on_command cmd_help, "link", "tweet", "show" do |c, owner, args|
        args.split(" ").each do |i|
          begin
            cache_id, tweet = extract_cache_id_from_number_or_url i, true

            if tweet
              twitter_user = get_twitter_user_from_tweet tweet
              cursor_text = get_cursor_text_from_tweet tweet, cache_id
              render_tweet_standard(channel, cursor_text, true, tweet, twitter_user, "", false, true)
              channel.msg twitter_user, "--link [ #{tweet.uri.to_s} ]"

              rvline = []
              rvline << "RT: #{tweet.retweet_count}" if tweet.retweet_count > 0
              rvline << "LK: #{tweet.favorite_count}" if tweet.favorite_count > 0
              channel.msg twitter_user, "--" + (rvline.join(" - ")) if rvline.size > 0

              if tweet.place.is_a?(Twitter::Place)
                channel.msg twitter_user, "--from #{tweet.place.full_name} (#{tweet.place.country})"
              end
              src = Loofah.fragment(tweet.source).text
              channel.msg twitter_user, "--via #{src}"
            else
              raise "Tweet #{cache_id_display cache_id} doesn't exist"
            end
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end 
      end

      cmd_help = ["<username>[, <username> ...]", "Follow user(s)", false]
      channel.on_command cmd_help, "follow" do |c, owner, args|
        @last_transact = []
        args.split(" ").each do |i|
          begin
            f_users = @rest_client.follow(i)
            @last_transact << ['follow', i]
            f_users.each do |f_user|
              process_event owner, channel, [:follow, f_user], true
            end
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end

      cmd_help = ["<username>[, <username> ...]", "Unfollow user(s)", false]
      channel.on_command cmd_help, "unfollow" do |c, owner, args|
        args.split(" ").each do |i|
          begin
            f_users = @rest_client.unfollow(i)
            f_users.each do |f_user|
              process_event owner, channel, [:follow, f_user], true
            end
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end

      cmd_help = ["<username>[, <username> ...]", "Show user profile(s)", false]
      channel.on_command cmd_help, "info", "whois" do |c, owner, args|
        args.split(" ").each do |username|
          begin
            twitter_user = get_twitter_user_by_screen_name username.downcase
            user = nil
            if twitter_user
              user = twitter_user.twitter_user
            else
              user = @rest_client.user(username)
              twitter_user = TwitterUser.new(user)
              @twitter_users << twitter_user
            end

            channel.msg owner.control_user, "#{user.screen_name} is #{user.name} from #{user.location} [ #{user.uri.to_s} ]"
            channel.msg owner.control_user, "[Protected User]" if user.protected?
            channel.msg owner.control_user, "Follows you!" if @followers.include?(user.id)
            channel.msg owner.control_user, "Picture: #{user.profile_image_url_https(:bigger).to_s}"

            user.description.split("\n").each do |line|
              channel.msg owner.control_user, line
            end
            channel.msg owner.control_user, "Website: #{user.website.to_s}" if user.website?
            channel.msg owner.control_user, "Following: #{user.friends_count} - Followers: #{user.followers_count}"
            channel.msg owner.control_user, "Current Time: #{fmt_time Time.now, user.time_zone} (#{user.time_zone})"
            channel.msg owner.control_user, "-End of INFO list-"
          rescue Twitter::Error::NotFound => e
            raise "User #{username} does not exist"
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end

      cmd_help = ["<username>[, <username> ...]", "Mute user(s)", false]
      channel.on_command cmd_help, "mute", "m", "mu" do |c, owner, args|
        args.split(" ").each do |username|
          begin
            twitter_user = get_twitter_user_by_screen_name username.downcase
            user = nil
            if twitter_user
              user = twitter_user.twitter_user
            else
              user = @rest_client.user(username)
              twitter_user = TwitterUser.new(user)
              @twitter_users << twitter_user
            end
            add_to_mute_list user.id
            channel.msg owner.control_user, "User #{user.screen_name} has been muted."
          rescue Twitter::Error::NotFound => e
            raise "User #{username} does not exist"
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end

      cmd_help = ["<liked word> [<unliked word>]","Sets custom liked/unliked word", false]
      channel.on_command cmd_help, "set_like_text" do |c, owner, args|
        liked, unliked = args.split(" ")
        if liked.nil? || liked.blank?
          raise "You must specify the liked word"
        end
        update_prefs do |p|
          p['like_text'] = [liked, unliked || "un" + liked]
        end
        channel.msg owner.control_user, "Set liked words to: #{liked_word} #{unliked_word}"
      end

      cmd_help = ["","Hide follow notifications", false]
      channel.on_command cmd_help, "hide_follow" do |c, owner, args|
        update_prefs do |p|
          p['hide_follow'] = true
        end
        channel.msg owner.control_user, "Hiding follow notifications."
      end

      cmd_help = ["","Show follow notifications", false]
      channel.on_command cmd_help, "show_follow" do |c, owner, args|
        update_prefs do |p|
          p['hide_follow'] = false
        end
        channel.msg owner.control_user, "Showing follow notifications."
      end

      cmd_help = ["<username>[, <username> ...]", "Unmute user(s)", false]
      channel.on_command cmd_help, "unmute", "um", "unmu" do |c, owner, args|
        args.split(" ").each do |username|
          begin
            twitter_user = get_twitter_user_by_screen_name username.downcase
            user = nil
            if twitter_user
              user = twitter_user.twitter_user
            else
              user = @rest_client.user(username)
              twitter_user = TwitterUser.new(user)
              @twitter_users << twitter_user
            end
            remove_from_mute_list user.id
            channel.msg owner.control_user, "User #{user.screen_name} has been unmuted."
          rescue Twitter::Error::NotFound => e
            raise "User #{username} does not exist"
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end


      cmd_help = ["<id or url>[, <id or url> ...]", "Retweet+Like tweet(s)", false]
      channel.on_command cmd_help, "rk", "rv" do |c, owner, args|
        args.split(" ").each do |i|
          begin
            @last_transact = []
            cache_id, tweet = extract_cache_id_from_number_or_url i
            if tweet
              rts = @rest_client.retweet(tweet.id)
              rts.each do |rt|
                @last_transact << ['rt', rt.id]
                process_event owner, channel, [:tweet, rt]
              end
              @rest_client.favorite(tweet.id)
              @last_transact << ['fv', tweet.id]
              process_event owner, channel, [:favorite, tweet], true, refetch: true
            else
              raise "Tweet #{cache_id_display cache_id} doesn't exist"
            end
          rescue => e
            channel.msg owner.control_user, "ERROR! #{e.message}"
          end
        end
      end

      cmd_help = ["<id or url>[, <id or url> ...]", "Like+Retweet tweet(s)", false]
      channel.on_command cmd_help, "lt", "ft" do |c, owner, args|
        args.split(" ").each do |i|
          begin
            @last_transact = []
            cache_id, tweet = extract_cache_id_from_number_or_url i
            if tweet
              @rest_client.favorite(tweet.id)
              @last_transact << ['fv', tweet.id]
              process_event owner, channel, [:favorite, tweet], true, refetch: true

              rts = @rest_client.retweet(tweet.id)
              rts.each do |rt|
                @last_transact << ['rt', rt.id]
                process_event owner, channel, [:tweet, rt], refetch: true
              end
            else
              raise "Tweet #{cache_id_display cache_id} doesn't exist"
            end
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end

      cmd_help = ["<id or url>[, <id or url> ...]", "Like tweet(s)", false]
      channel.on_command cmd_help, "lk", "like", "lv", "fv", "fav" do |c, owner, args|
        args.split(" ").each do |i|
          begin
            @last_transact = []
            cache_id, tweet = extract_cache_id_from_number_or_url i
            if tweet
              @rest_client.favorite(tweet.id)
              @last_transact << ['fv', tweet.id]
              process_event owner, channel, [:favorite, tweet], true, refetch: true
            else
              raise "Tweet #{cache_id_display cache_id} doesn't exist"
            end
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end

      cmd_help = ["<id or url>[, <id or url> ...]", "Unlike tweet(s)", false]
      channel.on_command cmd_help, "ulk", "ulike", "ulv", "ufv", "unfav" do |c, owner, args|
        args.split(" ").each do |i|
          begin
            cache_id, tweet = extract_cache_id_from_number_or_url i
            if tweet
              @rest_client.unfavorite(tweet.id)
              process_event owner, channel, [:unfavorite, tweet], true, refetch: true
            else
              raise "Tweet #{cache_id_display cache_id} doesn't exist"
            end
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end

      cmd_help = ["<id or url> <text>]", "Reply to tweet (to sender only)", false]
      channel.on_command cmd_help, "rs" do |c, owner, args|
        i, sep, args = args.partition(" ")
        if args.strip.size == 0
          raise "You didn't enter any text!"
        else
          cache_id, tweet = extract_cache_id_from_number_or_url i
          if tweet
            recipient = get_preferred_recipient_from_tweet tweet
            mentions = nil
            mentions = "@#{recipient}" unless recipient.nil?
            post_update channel, args, mentions, {in_reply_to_status_id: tweet.id}
          else
            raise "Tweet #{cache_id_display cache_id} doesn't exist"
          end
        end
      end

      cmd_help = ["<id or url> <text>]", "Reply to tweet (with no default mentions)", false]
      channel.on_command cmd_help, "rr" do |c, owner, args|
        i, sep, args = args.partition(" ")
        if args.strip.size == 0
          raise "You didn't enter any text!"
        else
          cache_id, tweet = extract_cache_id_from_number_or_url i
          if tweet
            post_update channel, args, nil, {in_reply_to_status_id: tweet.id}
          else
            raise "Tweet #{cache_id_display cache_id} doesn't exist"
          end
        end
      end

      cmd_help = ["<id or url> <text>]", "Reply to tweet (to all people on the tweet)", false]
      channel.on_command cmd_help, "re", "ra", "reply" do |c, owner, args|
        i, sep, args = args.partition(" ")
        if args.strip.size == 0
          raise "You didn't enter any text!"
        else
          cache_id, tweet = extract_cache_id_from_number_or_url i
          if tweet
            mentions = [tweet.user.screen_name] + tweet.user_mentions.map { |u| u.screen_name }
            mentions = mentions.select { |m| m.downcase != owner.nick.downcase }.uniq.compact
            mentions = mentions.map { |m| "@#{m}" }.join(" ").strip
            mentions = nil if mentions.strip.size == 0
            post_update channel, args, mentions, {in_reply_to_status_id: tweet.id}
          else
            raise "Tweet #{cache_id_display cache_id} doesn't exist"
          end
        end
      end

      cmd_help = ["<id or url> <text>]", "Public .reply to tweet (to sender only)", false]
      channel.on_command cmd_help, "prs" do |c, owner, args|
        i, sep, args = args.partition(" ")
        if args.strip.size == 0
          raise "You didn't enter any text!"
        else
          cache_id, tweet = extract_cache_id_from_number_or_url i
          if tweet
            recipient = get_preferred_recipient_from_tweet tweet
            mentions = nil
            mentions = "@#{recipient}" unless recipient.nil?
            post_update channel, args, mentions, {in_reply_to_status_id: tweet.id, prefix: "."}
          else
            raise "Tweet #{cache_id_display cache_id} doesn't exist"
          end
        end
      end

      cmd_help = ["<id or url> <text>]", "Public .reply to tweet (to all people on tweet)", false]
      channel.on_command cmd_help, "pre", "pra" do |c, owner, args|
        i, sep, args = args.partition(" ")
        if args.strip.size == 0
          raise "You didn't enter any text!"
        else
          cache_id, tweet = extract_cache_id_from_number_or_url i
          if tweet
            mentions = [tweet.user.screen_name] + tweet.user_mentions.map { |u| u.screen_name }
            mentions = mentions.select { |m| m.downcase != owner.nick.downcase }.uniq.compact
            mentions = mentions.map { |m| "@#{m}" }.join(" ").strip
            mentions = nil if mentions.strip.size == 0
            post_update channel, args, mentions, {in_reply_to_status_id: tweet.id, prefix: "."}
          else
            raise "Tweet #{cache_id_display cache_id} doesn't exist"
          end
        end
      end

      cmd_help = ["<username> [<count>]", "Show <count> or 20 most recent tweets for <username>", false]
      channel.on_command cmd_help, "tweets" do |c, owner, args|
        a = args.split(" ").map(&:strip)
        if a.size < 0
          raise "You didn't specify a username. Syntax is: tweets <username> [<number of tweets (default 20, max 200)>]"
        end

        u = a[0].downcase
        n = (a[1] || "20").to_i rescue 20
        channel.msg owner.control_user, "Fetching #{u}'s tweets..."
        timeline = @rest_client.user_timeline(u, count: n, tweet_mode: 'extended')
        timeline = timeline.uniq.compact.sort { |a,b| a.created_at <=> b.created_at }
        timeline.each do |obj|
          process_event owner, channel, [:tweet, obj], true, true
        end
        channel.msg owner.control_user, "-End of #{u}'s tweets-"
      end

      cmd_help = ["<id or url>[, <id or url> ...]", "Show replies for tweet(s)", false]
      channel.on_command cmd_help, "conv", "replies", "rp" do |c, owner, args|
        args.split(" ").each do |i|
          begin
            @last_transact = []
            cache_id, tweet = extract_cache_id_from_number_or_url i
            if tweet
              channel.msg owner.control_user, "Fetching conversation for #{cache_id_display(cache_id)}..."
              chain = get_chain_for_tweet(tweet)
              chain.each { |t| render_tweet_quick channel, t }
              channel.msg owner.control_user, "-End of conversation for #{cache_id_display(cache_id)}-"
            else
              raise "Tweet #{cache_id_display cache_id} doesn't exist"
            end
          rescue => e
            print_error channel, e, "ERROR!"
          end
        end
      end

      cmd_help = ["", "search is broken don't use", true]
      channel.on_command cmd_help, "search", "s" do |c, owner, args|
        n, p, q = args.partition(" ").map(&:strip)
        if n.size < 1 || q.size < 1
          raise "You must specify a channel name and a search query. Syntax is: search <channel name> <query>"
        end
        if !n.start_with?('#')
          raise "Channel name must begin with '#'."
        end
        create_search_channel n, q
      end

      cmd_help = ["", "Undo last action", false]
      channel.on_command cmd_help, "undo", "u" do |c, owner, args|
        if @last_transact.nil? || @last_transact.size == 0
          raise "Nothing to undo!"
        else
          @last_transact.each do |tran|
            tran_type, id = tran
            case tran_type
            when 'update'
              @rest_client.destroy_status id
            when 'rt'
              @rest_client.destroy_status id
            when 'fv'
              @rest_client.unfavorite id
            when 'follow'
              @rest_client.unfollow id
            else
              raise "Don't know how to undo '#{tran_type}'"
            end
          end
          @last_transact = []
        end
      end

      cmd_help = ["", "Show list of commands", false]
      channel.on_command cmd_help, "help", "h", "?" do |c, owner, args|
        begin
          help = channel.get_command_help
          channel.msg owner.control_user, "Commands list:"
          help.each do |cs, hs|
            channel.msg owner.control_user, "#{cs.join(", ")} #{hs[0]} - #{hs[1]}"
          end
          channel.msg owner.control_user, "--End of commands list--"
        rescue => e
          print_error channel, e, "Some shit happened!"
        end
      end

    end

  end

  def get_chain_for_tweet(tweet)
    search_name = tweet.user.screen_name
    res1        = @rest_client.user_timeline(search_name, since_id: tweet.id, count: 200, tweet_mode: 'extended')
    res2        = @rest_client.search("@#{search_name}", since_id: tweet.id, count: 200, tweet_mode: 'extended').tap.each {}.to_a
    results     = (res1 + res2).sort { |a, b| a.id <=> b.id }.uniq.compact
    related_ids = [tweet.id]
    2.times { results.each { |t| related_ids << t.id if related_ids.include?(t.in_reply_to_status_id) } }
    chain = [tweet]
    results.each { |t| chain << t if related_ids.include?(t.id) }
    chain
  end

  def extract_cache_id_from_number_or_url(i, reload=false)
    if i.start_with?("https://twitter.com/")
      status_id = i.split("/").last
      tweet     = get_tweet_from_cache status_id, reload
      if tweet.nil?
        tweet = @rest_client.status(status_id, tweet_mode: 'extended')
      end
      cache_id, entry = get_cache_id_and_entry tweet
    else
      cache_id = convert_cache_id i
    end

    if tweet.nil?
      tweet = get_tweet_by_cache_id cache_id, reload
    end

    return cache_id, tweet
  end

  def setup_control_channel channel
    @control_channel = channel
    cmd_help = ["", "", true]
    channel.on_command cmd_help, "post" do |channel, owner, args|
      channel.msg owner.control_user, "YOU SAID #{args}"
    end
  end

  def get_twitter_user_by_screen_name screen_name
    @twitter_users.detect { |u| u.nick.downcase == screen_name.downcase }    
  end

  def post_dm(recipient, text)
    text = text.strip
    @last_dm_transact = []
    multi_delimiter = "./."

    text.split(multi_delimiter).each do |part|
      new_dm = @rest_client.create_direct_message(recipient, part)
      @last_dm_transact << ['dm', new_dm.id]
    end
  end

  def assign_handlers
    @htmlentities = HTMLEntities.new
    @twitter_users = []
    @followers = []
    @logged_in = false
    @oauth_step = 0
    @threads = []
    @cursor = 1
    @dm_cursor = 1
    @tweet_cache = [nil] * CACHE_SIZE
    @dm_cache = [nil] * CACHE_SIZE
    @last_dm_transact = []

    handler_pm_command "post", "p" do |owner, target, args|
      begin
        if args.strip.size == 0
          raise "You didn't enter any text!"
        else
            post_dm target, args
        end
      rescue => e
        u = get_twitter_user_by_screen_name(target)
        if u
          owner.msg get_twitter_user_by_screen_name(target), "ERROR! #{e.message}"
        else
          owner.msg owner.control_user, "ERROR! You can't DM #{target}."
        end
      end
    end

    handler_pm_command "ext", "x" do |owner, target, args|
      begin
        if args.strip.size == 0
          raise "You didn't enter any text!"
        else
            post_dm target, args
        end
      rescue => e
        u = get_twitter_user_by_screen_name(target)
        if u
          owner.msg get_twitter_user_by_screen_name(target), "ERROR! #{e.message}"
        else
          owner.msg owner.control_user, "ERROR! You can't DM #{target}."
        end
      end
    end      

    handler_pm_command "dl", "rm" do |owner, target, args|
      args.split(" ").each do |i|
        begin
          cache_id = convert_cache_id i
          dm = @dm_cache[cache_id]
          if dm
            @rest_client.direct_message_destroy(dm.id)
            s, r = get_user_pair_from_dm dm
            if s.nick.downcase == owner.nick.downcase
              st = r
            else
              st = s
            end
            owner.msg st, "[DM #{cache_id_display cache_id} deleted]"
          else
            raise "DM #{cache_id_display cache_id} doesn't exist"
          end
        rescue => e
          u = get_twitter_user_by_screen_name(target)
          if u
            owner.msg get_twitter_user_by_screen_name(target), "ERROR! #{e.message}"
          else
            owner.msg owner.control_user, "ERROR! You can't DM #{target}."
          end
        end
      end
    end

    handler_pm_command "undo", "u" do |owner, target, args|
      if @last_dm_transact.nil? || @last_dm_transact.size == 0
        raise "Nothing to undo!"
      else
        @last_dm_transact.each do |tran|
          tran_type, id = tran
          case tran_type
          when 'dm'
            dms = @rest_client.direct_message_destroy id
            dms.each do |dm|
              acid, tdm = get_dm_cache_id_and_entry dm
              s, r = get_user_pair_from_dm dm
              if s.nick.downcase == owner.nick.downcase
                st = r
              else
                st = s
              end
              owner.msg st, "[DM #{cache_id_display acid} deleted]"
            end
          else
            raise "Don't know how to undo '#{tran_type}'"
          end
        end
        @last_dm_transact = []
      end
    end


    handler_serv_command "nickserv", "register" do |owner, args|
      if @logged_in
        owner.serv_notice "NickServ", "You are already logged in!"
      elsif @oauth_step == 1
        owner.serv_notice "NickServ", "1. Please navigate to #{@request_token.authorize_url}"
        owner.serv_notice "NickServ", "2. Then provide your pin code by typing: /msg NickServ AUTH <pincode>"
      else
        parse_user = load_parse_user owner.nick.downcase
        if parse_user
          owner.serv_notice "NickServ", "The user #{owner.nick.downcase} is already registered."
          owner.serv_notice "NickServ", "If you are trying to log in use: /msg NickServ IDENTIFY <password>"
        else
          @user_password = encrypt_pass(args)
          @consumer = OAuth::Consumer.new(TWITTER_CLIENT_ID, TWITTER_CLIENT_SECRET, :site => "https://api.twitter.com" )
          @request_token = @consumer.get_request_token
          owner.serv_notice "NickServ", "1. Please navigate to #{@request_token.authorize_url}"
          owner.serv_notice "NickServ", "2. Then provide your pin code by typing: /msg NickServ AUTH <pincode>"
          @oauth_step = 1
        end
      end
    end
    handler_serv_command "nickserv", "identify" do |owner, args|
      if @logged_in
        owner.serv_notice "NickServ", "You are already logged in!"
      elsif @oauth_step == 1
        owner.serv_notice "NickServ", "1. Please navigate to #{@request_token.authorize_url}"
        owner.serv_notice "NickServ", "2. Then provide your pin code by typing: /msg NickServ AUTH <pincode>"
      else
        parse_user = load_parse_user owner.nick.downcase
        if parse_user
          if encrypt_pass(args) != parse_user['password']
            owner.control_msg "Wrong password!"
          else
            after_login parse_user, owner.nick.downcase
          end
        else
          owner.serv_notice "NickServ", "The user #{owner.nick.downcase} has not been registered."
          owner.serv_notice "NickServ", "Please register by using: /msg NickServ REGISTER <password>"
        end
      end
    end

    handler_serv_command "nickserv", "auth" do |owner, args|
      if @logged_in
        owner.serv_notice "NickServ", "You are already logged in!"
      elsif @oauth_step == 1
        begin
          @access_token = @request_token.get_access_token :oauth_verifier => args
          owner.serv_notice "NickServ", "OK! You were authenticated.  Welcome!"
          owner.serv_notice "NickServ", "From now on, use this to login: /msg NickServ IDENTIFY <password>"
          @oauth_step = 0

          parse_user = {}
          parse_user['password'] = @user_password
          parse_user["authToken"] = Blowfish.encrypt(BF_KEY,@access_token.token)
          parse_user["authSecret"] = Blowfish.encrypt(BF_KEY,@access_token.secret)
          result = save_parse_user_file owner.nick.downcase, user: parse_user
          @oauth_step = 0
          after_login parse_user, owner.nick.downcase
        rescue => e
          owner.serv_notice "NickServ", "OH NO! #{e.message}"
        end
      else
        owner.serv_notice "NickServ", "You did something wrong. Read carefully."
      end
    end

    handler_irc_command "whois" do |owner, prefix, params|
      username = params.first
      begin
        twitter_user = get_twitter_user_by_screen_name username.downcase
        user = nil
        if twitter_user
          user = twitter_user.twitter_user
        else
          user = @rest_client.user(username)
          twitter_user = TwitterUser.new(user)
          @twitter_users << twitter_user
        end
        
        owner.send_numeric 311, user.screen_name, user.screen_name, "twitter.com", "*", user.name
        user.description.split("\n").each do |line|
          owner.send_numeric 313, user.screen_name, line
        end
        owner.send_numeric 312, user.screen_name, user.uri.to_s, "from #{user.location}"
        owner.send_numeric 313, user.screen_name, "[Protected User]" if user.protected?

        owner.send_numeric 313, user.screen_name, "Follows you!" if @followers.include?(user.id)


        owner.send_numeric 313, user.screen_name, "Website: #{user.website.to_s}" if user.website?
        owner.send_numeric 313, user.screen_name, "Following: #{user.friends_count} - Followers: #{user.followers_count}"
        owner.send_numeric 313, user.screen_name, "Current Time: #{fmt_time Time.now, user.time_zone} (#{user.time_zone})"
        owner.send_numeric 318, user.screen_name, "End of WHOIS list"
      rescue Twitter::Error::NotFound => e
        owner.send_numeric 401, username, "User does not exist."
      rescue => e
        owner.send_numeric 401, username, "Error retrieving the user. #{e.message}"
      end
    end
  end
end

server = Server.new TwitterController

server.run

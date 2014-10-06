require 'digest/sha2'
require 'rack/utils'
require 'rack/request'
require 'json'
require 'hiredis'
require 'redis'
require 'redis/connection/hiredis'
require 'erubis'

module Isucon4
  class App
    USER_LOCK_THRESHOLD = 3
    IP_BAN_THRESHOLD = 10

    VIEWS_DIR = "#{__dir__}/views"
    LAYOUT_REPLACER = '<%= yield %>'

    def self.users
      @users ||= {}
    end

    def self.view(name)
      @views ||= {}
      @views[name] ||= begin
        path = File.join(VIEWS_DIR, "#{name}.erb")
        Erubis::FastEruby.new(File.read(path)).tap do |erb|
          erb.filename = path
        end
      end
    end

    def self.layout(name)
      @layouts ||= {}
      e = @layouts[name]
      return e if e

      body = layout_(name) { LAYOUT_REPLACER }.split(LAYOUT_REPLACER).each(&:freeze)
      @layouts[name] = body
    end

    def self.layout_(name)
      view(name).result(binding)
    end

    INDEX_NORMAL = 0
    INDEX_LOCKED = 1
    INDEX_BANNED = 2
    INDEX_WRONG  = 3
    INDEX_MUST_LOGGED_IN = 4
    INDEX_VIEWS = [
      [nil],
      ["This account is locked."],
      ["You're banned."],
      ["Wrong username or password"],
      ["You must be logged in"],
    ].tap do |views|
      views.each do |body|
        body[0] = [layout(:base)[0], self.view(:index).evaluate(notice: body[0]), layout(:base)[1]].join
      end
    end

    def self.call(env)
      self.new(env).call
    end

    def initialize(env)
      @env = env
      @status = nil
      @headers = {}
      @body = []
    end

    module ResponseMethods
      def response
        [@status || 200, @headers, @body]
      end

      def content_type(type)
        @headers['Content-Type'] = type
      end

      def render(template, layout = :base)
        @headers['Content-Type'] ||= 'text/html'
        @status ||= 200
        @body = erb(template, layout)
      end

      def erb(name, layout = :base)
        if layout
          l = App.layout(layout)
          [l[0], erb(name, nil), l[1]]
        else
          App.view(name).result(binding)
        end
      end

      def not_found
        @status = 404
        @headers = {'Content-Type' => 'text/plain'}
        @body = ['not found']
      end

      def redirect(path)
        if @env['HTTP_VERSION'] == 'HTTP/1.1' && @env["REQUEST_METHOD"] != 'GET'
          @status = 303
        else
          @status = 302
        end

        @headers['Location'] = path
      end
    end

    module Helpers
      def request
        @request ||= Rack::Request.new(@env)
      end

      def cookies
        @cookies ||= request.cookies.tap(&:freeze)
      end

      def cookie_set(key, value)
        (@headers['Set-Cookie'] ||= '') << "#{key}=#{Rack::Utils.escape(value || '')}; path=/\n"
      end

      def cookie_rem(key)
        (@headers['Set-Cookie'] ||= '') << "#{key}=; path=/; max-age=0\n"
      end

      def notice
        
      end

      def params
        @params ||= request.params
      end

      def calculate_password_hash(password, salt)
        Digest::SHA256.hexdigest "#{password}:#{salt}"
      end

      def redis
        # assuming each object isn't shared across threads
        @redis ||= Redis.current
      end


        
      def redis_key_user(login)
        "isu4:user:#{login}"
      end

      def redis_key_userfail(user)
        "isu4:userfail:#{user['login']}"
      end

      def redis_key_last(user)
        "isu4:last:#{user['login']}"
      end

      def redis_key_nextlast(user = {'id' => '*'})
        "isu4:nextlast:#{user['login']}"
      end

      def redis_key_ip(ip)
        "isu4:ip:#{ip}"
      end

      def get_user(login)
        # App.users[login] ||= 
        redis.hgetall(redis_key_user(login))
      end

      def login_log(succeeded, login, user = nil)
        kuser = user && redis_key_userfail(user) 
        kip = redis_key_ip(request.ip)

        if succeeded
          klast, knextlast = redis_key_last(user), redis_key_nextlast(user)
          redis.mset kip, 0, kuser, 0

          redis.rename(knextlast, klast) rescue nil # Redis::CommandError
          redis.hmset knextlast, 'at', Time.now.to_i, 'ip', request.ip
        else
          redis.incr kip
          redis.incr kuser
        end
      end

      def user_locked?(user)
        return nil unless user
        failures = redis.get(redis_key_userfail(user))
        failures = failures && failures.to_i

        failures && USER_LOCK_THRESHOLD <= failures
      end

      def ip_banned?
        failures = redis.get(redis_key_ip(request.ip))
        failures = failures && failures.to_i

        failures && IP_BAN_THRESHOLD <= failures
      end

      def attempt_login(login, password)
        user = get_user(login)

        if ip_banned?
          login_log(false, login, user)
          return [nil, :banned]
        end

        if user_locked?(user)
          login_log(false, login, user)
          return [nil, :locked]
        end

        if user && calculate_password_hash(password, user['salt']) == user['password']
          login_log(true, login, user)
          [user, nil]
        elsif user
          login_log(false, login, user)
          [nil, :wrong_password]
        else
          login_log(false, login)
          [nil, :wrong_login]
        end
      end

      def current_user
        return @current_user if @current_user
        login = cookies['login']
        return nil unless login

        @current_user = get_user(login)
        unless @current_user
          cookie_set :login, nil
          return nil
        end

        @current_user
      end

      def last_login
        @last_login ||= begin
          cur = current_user
          return nil unless cur
          last = redis.hgetall(redis_key_last(cur))
          last.empty? ? redis.hgetall(redis_key_nextlast(cur)) : last
        end
      end

      def banned_ips
        redis.keys('isu4:ip:*').select do |key|
          failures = redis.get(key).to_i
          IP_BAN_THRESHOLD <= failures
        end.map do |key|
          key[8..-1]
        end
      end

      def locked_users
        redis.keys('isu4:userfail:*').select do |key|
          failures = redis.get(key).to_i
          USER_LOCK_THRESHOLD <= failures
        end.map do |key|
          key[14..-1]
        end
      end
    end

    module Actions
      def action_index
        content_type 'text/html'
        cookie_rem :notice
        n = cookies['notice']
        @body = INDEX_VIEWS[n ? n.to_i : 0]
      end

      def action_login
        user, err = attempt_login(params['login'], params['password'])
        if user
          cookie_set :login, user['login']
          redirect '/mypage'
        else
          case err
          when :locked
            cookie_set :notice, INDEX_LOCKED
          when :banned
            cookie_set :notice, INDEX_BANNED
          else
            cookie_set :notice, INDEX_WRONG
          end
          redirect '/'
        end
      end

      def action_mypage
        unless current_user
          cookie_set :notice, INDEX_MUST_LOGGED_IN
          return redirect '/'
        end
        render :mypage
      end

      def action_report
        content_type 'application/json'
        @body = [{
          banned_ips: banned_ips,
          locked_users: locked_users,
        }.to_json]
      end
    end

    include ResponseMethods
    include Helpers
    include Actions

    def call
      meth = @env['REQUEST_METHOD'.freeze]
      path = @env['PATH_INFO'.freeze]

      case
      when path == '/login'.freeze
        action_login
      when meth == 'GET'.freeze
        case path
        when '/'.freeze
          action_index
        when '/mypage'.freeze
          action_mypage
        when '/report'.freeze
          action_report
        else
          not_found
        end
      else
        not_found
      end

      @body = [@body] unless @body.respond_to?(:each)
      response
    end
  end
end

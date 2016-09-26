require 'sinatra'
require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'

module Bunseki

end

class Bunseki::WebApp < Sinatra::Base
  set :public_folder, File.dirname(__FILE__) + '/assets'
  set :haml, escape_html: true

  helpers do
    def config
      @config ||= {
        db: {
          host: ENV['BUNSEKI_DB_HOST'] || 'localhost',
          port: ENV['BUNSEKI_DB_PORT'] && ENV['BUNSEKI_DB_PORT'].to_i,
          username: ENV['BUNSEKI_DB_USER'] || 'root',
          password: ENV['BUNSEKI_DB_PASSWORD'],
          database: ENV['BUNSEKI_DB_NAME'] || 'bunseki',
        },
      }
    end

    def db
      return Thread.current[:bunseki_db] if Thread.current[:bunseki_db]
      client = Mysql2::Client.new(
        host: config[:db][:host],
        port: config[:db][:port],
        username: config[:db][:username],
        password: config[:db][:password],
        database: config[:db][:database],
        reconnect: true,
      )
      client.query_options.merge!(symbolize_keys: true)
      Thread.current[:isucon5_db] = client
      client
    end

    def build_cond(cond = {})
      cond.map do |k, v|
        "#{k}=#{URI.escape(v)}"
      end.join('&')
    end

    def build_where(cond = {})
      where = 'where 1 = 1 '
      cond.each do |k, v|
        next if v == '' || v == nil
        if k == 'session'
          where += " and (req_header like '%#{v}%' or res_header like '%#{v}%')"
        else
          where += " and `#{k}` = '#{v}'"
        end
      end
      where
    end

    def count(cond = {})
      where = build_where(cond)
      query = <<SQL
select count(1) as count from raw_http_logs #{where}
SQL
      db.xquery(query).first[:count].to_i
    end
  end

  before do
    request.script_name = ENV['SCRIPT_NAME']
  end

  get '/' do
    page = params[:page].to_i
    page = 1 if page == 0
    per = 20
    cond = params.select do |k, _|
      %w/method normalized_path path http_version status type session/.include? k
    end
    where = build_where(cond)

    query = <<-SQL
      select
        normalized_path
        , count(1) as count
        , sum(res_time) sum_res_time
        , avg(res_time) ave_res_time
        , min(res_time) min_res_time
        , max(res_time) max_res_time
      from raw_http_logs #{where}
      group by normalized_path
    SQL
    @summary = db.xquery(query)

    query = <<-SQL
      select * from raw_http_logs #{where} order by id desc limit #{(page - 1) * per}, #{per}
    SQL
    @logs = db.xquery(query)
    @count = count(cond)
    @cond = build_cond(cond)
    haml :index
  end

  get '/:id' do
    query = <<-SQL
      select * from raw_http_logs where id = ?
    SQL
    @log = db.xquery(query, params['id']).first
    halt 404 unless @log

    query = <<-SQL
      select * from raw_sql_logs where request_id = ?
    SQL
    @sqls = db.xquery(query, @log[:request_id])
    haml :show
  end

  get '/requests/:request_id' do
    log = db.xquery('select id from raw_http_logs where request_id = ?', params['request_id']).first
    halt 404 unless log
    redirect to "/#{log[:id]}", 303
  end

  get '/sessions/' do
    @sessions = db.xquery('select req_header from raw_http_logs').map do |rel|
      if rel[:req_header] =~ /Cookie: (.*)/
        $1
      end
    end.compact.uniq
    haml :sessions
  end

  get '/explain/:id' do
    @sql = db.xquery('select * from raw_sql_logs where id = ?', params[:id]).first
    halt 404 unless @sql
    @stats = db.query("explain #{@sql[:sql_text]}").to_a
    db.query('set profiling=0')
    db.query('set profiling_history_size=0')
    db.query('set profiling=1')
    db.query('set profiling_history_size=15')
    @results = db.query(@sql[:sql_text]).to_a
    @profile = db.query('show profile source for query 1').to_a
    haml :explain
  end
end

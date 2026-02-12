require "sinatra/base"
require "json"

class DashboardApp < Sinatra::Base
  set :public_folder, File.join(__dir__, "public")
  set :logging, false
  set :server, :puma
  set :server_settings, { Silent: true }

  get "/" do
    send_file File.join(settings.public_folder, "index.html")
  end

  get "/events" do
    content_type "text/event-stream"
    cache_control :no_cache
    headers "X-Accel-Buffering" => "no", "Connection" => "keep-alive"

    bridge = settings.bridge

    stream do |out|
      last_id = (params[:last_id] || 0).to_i

      loop do
        events = bridge.events_since(last_id)
        events.each do |evt|
          out << "id: #{evt[:id]}\ndata: #{JSON.generate(evt)}\n\n"
          last_id = evt[:id]
        end

        sleep 0.15
      rescue Errno::EPIPE, IOError
        break
      end
    end
  end

  get "/stats" do
    content_type :json
    bus = settings.bus

    stats = {}
    bus.channel_names.each do |name|
      ch_stats = bus.stats(name)
      stats[name] = {
        published: ch_stats[:published],
        delivered: ch_stats[:delivered],
        nacked:    ch_stats[:nacked],
        dlq_depth: bus.dead_letters(name).size
      }
    rescue
      stats[name] = { published: 0, delivered: 0, nacked: 0, dlq_depth: 0 }
    end

    JSON.generate(stats)
  end
end

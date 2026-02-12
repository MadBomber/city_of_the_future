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

  post "/calls" do
    content_type :json
    body = JSON.parse(request.body.read)

    call_id = "L-#{Time.now.strftime('%H%M%S')}"

    call = EmergencyCall.new(
      call_id:     call_id,
      caller:      body["caller"] || "Dashboard",
      location:    body["location"] || "Unknown",
      description: body["description"],
      severity:    (body["severity"] || "high").to_sym,
      timestamp:   Time.now
    )

    settings.call_queue << call

    JSON.generate({ call_id: call_id, status: "queued" })
  end

  get "/stats" do
    content_type :json
    bus = settings.bus

    all_stats = bus.stats.to_h
    result = {}

    bus.channel_names.each do |name|
      pub_key  = :"#{name}_published"
      del_key  = :"#{name}_delivered"
      nack_key = :"#{name}_nacked"

      result[name] = {
        published: all_stats[pub_key] || 0,
        delivered: all_stats[del_key] || 0,
        nacked:    all_stats[nack_key] || 0,
        dlq_depth: bus.dead_letters(name).size
      }
    end

    JSON.generate(result)
  end
end

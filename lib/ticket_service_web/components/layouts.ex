defmodule TicketServiceWeb.Layouts do
  use Phoenix.Component

  def app(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Occupancy Dashboard</title>
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #e2e8f0; }
          .container { max-width: 1200px; margin: 0 auto; padding: 2rem; }
          h1 { font-size: 1.875rem; font-weight: 700; margin-bottom: 1.5rem; }
          h2 { font-size: 1.25rem; font-weight: 600; margin-bottom: 1rem; color: #94a3b8; }
          .card { background: #1e293b; border-radius: 0.75rem; padding: 1.5rem; margin-bottom: 1.5rem; border: 1px solid #334155; }
          .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 1.5rem; }
          .stat-value { font-size: 3rem; font-weight: 800; line-height: 1; }
          .stat-label { font-size: 0.875rem; color: #94a3b8; margin-top: 0.25rem; }
          .progress-bar { height: 1.5rem; background: #334155; border-radius: 0.75rem; overflow: hidden; margin-top: 1rem; }
          .progress-fill { height: 100%; border-radius: 0.75rem; transition: width 0.3s ease; }
          .fill-green { background: linear-gradient(90deg, #22c55e, #16a34a); }
          .fill-yellow { background: linear-gradient(90deg, #eab308, #ca8a04); }
          .fill-red { background: linear-gradient(90deg, #ef4444, #dc2626); }
          .alert { padding: 1rem 1.5rem; border-radius: 0.5rem; margin-bottom: 1.5rem; font-weight: 600; }
          .alert-danger { background: #7f1d1d; border: 1px solid #ef4444; color: #fca5a5; }
          .alert-warning { background: #78350f; border: 1px solid #f59e0b; color: #fde68a; }
          table { width: 100%; border-collapse: collapse; }
          th, td { padding: 0.75rem 1rem; text-align: left; border-bottom: 1px solid #334155; }
          th { color: #94a3b8; font-weight: 600; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; }
          td { font-size: 0.95rem; }
          .badge { display: inline-block; padding: 0.25rem 0.75rem; border-radius: 9999px; font-size: 0.75rem; font-weight: 600; }
          .badge-green { background: #166534; color: #86efac; }
          .badge-red { background: #7f1d1d; color: #fca5a5; }
          .connected { color: #22c55e; }
          .disconnected { color: #ef4444; }
          .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 2rem; }
          .timestamp { font-size: 0.8rem; color: #64748b; }
        </style>
      </head>
      <body>
        <div class="container">
          {@inner_content}
        </div>
        <script src="https://cdn.jsdelivr.net/npm/phoenix@1.7.21/priv/static/phoenix.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@1.1.28/priv/static/phoenix_live_view.min.js"></script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: { _csrf_token: csrfToken }
          });
          liveSocket.connect();
        </script>
      </body>
    </html>
    """
  end
end

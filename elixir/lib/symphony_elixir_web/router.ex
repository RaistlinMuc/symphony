defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/projects/discovered", ProjectsApiController, :discovered)
    get("/api/v1/projects", ProjectsApiController, :index)
    post("/api/v1/projects", ProjectsApiController, :create)
    get("/api/v1/projects/status", ProjectsApiController, :status)
    put("/api/v1/projects/:id", ProjectsApiController, :update)
    delete("/api/v1/projects/:id", ProjectsApiController, :delete)
    post("/api/v1/projects/:id/enable", ProjectsApiController, :enable)
    post("/api/v1/projects/:id/disable", ProjectsApiController, :disable)
    get("/api/v1/projects/:id/readiness", ProjectsApiController, :readiness)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/discovered", ProjectsApiController, :method_not_allowed)
    match(:*, "/api/v1/projects", ProjectsApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/status", ProjectsApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/:id", ProjectsApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/:id/enable", ProjectsApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/:id/disable", ProjectsApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/:id/readiness", ProjectsApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end

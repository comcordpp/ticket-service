defmodule TicketServiceWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import TicketServiceWeb.ConnCase

      alias TicketServiceWeb.Router.Helpers, as: Routes

      @endpoint TicketServiceWeb.Endpoint
    end
  end

  setup tags do
    TicketService.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end

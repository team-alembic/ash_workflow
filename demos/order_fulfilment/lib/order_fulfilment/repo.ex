defmodule OrderFulfilment.Repo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :order_fulfilment

  def installed_extensions, do: ["ash-functions", "uuid-ossp", "citext"]

  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end

{:ok, _} = Application.ensure_all_started(:document_approval)

Ecto.Adapters.SQL.Sandbox.mode(DocumentApproval.Repo, :manual)

ExUnit.start()

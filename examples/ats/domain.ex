defmodule ATS.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ATS.CandidatePipeline
  end
end

defmodule ATS.Domain do
  use Ash.Domain

  resources do
    resource ATS.CandidatePipeline
  end
end

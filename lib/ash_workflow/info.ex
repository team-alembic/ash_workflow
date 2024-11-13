defmodule AshWorkflow.Info do
  use Spark.InfoGenerator, extension: AshWorkflow, sections: [:workflow]
end

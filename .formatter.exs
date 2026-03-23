spark_locals_without_parens = [
  step: 1,
  step: 2,
  transition: 1,
  transition: 2,
  timeout: 1,
  timeout: 2,
  route: 1,
  route: 2,
  action: 1,
  initial: 1,
  manual: 1,
  terminal: 1,
  policy: 1,
  on_success: 1,
  on_error: 1
]

# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter],
  import_deps: [:ash],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]

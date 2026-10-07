# {json}: a JSON literal on the right-hand side of JSON assertions (STEP_GLOSSARY.md).
# Parsed with JSON.parse and compared typed, so "12000" is not 12000.
ParameterType(
  name: "json",
  regexp: /"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|true|false|null|\[\]|\{\}/,
  transformer: ->(literal) { JSON.parse(literal) }
)

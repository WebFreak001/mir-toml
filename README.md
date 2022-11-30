# mir-toml

As a believer of mir-ion as great general serialization framework for D, I have implemented TOML support for mir-ion.

## Example

```d
import mir.toml;
import mir.serde;
import mir.algebraic;

import std.datetime.date;
import std.stdio;
import std.file : readText;

alias StringOrDouble = Algebraic!(string, double);

struct Person
{
    string name;
    @serdeKeys("dob")
    Date dayOfBirth;
}

struct Database
{
    bool enabled;
    ushort[] ports;
    StringOrDouble[][] data;
}

struct MyDocument
{
    // NOTE: regular members MUST come before members that are serialized as
    // tables or arrays of tables. (structs and struct arrays)
    // Otherwise an exception is thrown at runtime
    string title;

    // represented as `owner = { ... }` instead of creating an `[owner]` section
    @tomlInlineTable
    Person owner;

    Database database;
}

void main()
{
    MyDocument document = {
        title: "TOML Example",
        owner: Person(
            "Max Mustermann",
            Date(1979, 5, 27)
        ),
        database: Database(
            true,
            [8000, 8001, 8002],
            [
                [StringOrDouble(1.4), StringOrDouble("cool")],
                [],
                [StringOrDouble("ok")]
            ]
        )
    };

    writeln(serializeToml(document, TOMLBeautyConfig.full));

    /* output:
    title = "TOML Example"
    owner = { name = "Max Mustermann", dob = 1979-05-27 }

    [database]
      enabled = true
      ports = [ 8000, 8001, 8002 ]
      data = [ [ 1.4, "cool" ], [], [ "ok" ] ]
    */

    // parsing TOML:
    writeln(deserializeToml!MyDocument(readText("config.toml")));
}
```

See also: [examples.d](./source/mir/toml/examples.d) for tested examples.

## Implementation notes

Serializer:
- null values will either be omitted if possible or otherwise throw an exception at runtime
    - exception: typed empty array null is serialized as empty array
    - if you want to make optional fields, you should use `Variant!(void, T)` as type instead of Nullable.
- mixing structs (tables) and other values in arrays will throw an exception at runtime if tables don't come first
    - to fix this, annotate with `@tomlInlineArray` or change type to `TomlInlineArray!(T[])`
- string types can be enforced using `@tomlLiteralString` (`'string'`), `@tomlMultilineString` (`"""string"""`) or `@tomlMultilineLiteralString` (`'''string'''`) - however note that runtime exceptions may occur if they are not representable
- putting regular fields of a struct after table fields (struct members) will break at runtime
    - planned to be fixed, to support conversion between formats, but for now not supported
    - for serialization of D datatypes you can simply move your fields around to have the proper output, but you can't enforce this e.g. for parsed JSON

Deserializer:
- based on the `toml` library, which doesn't keep ordering of maps
- only deserializes values, does not keep track of aesthetic things like which tables were inlined, how numbers and strings are serialized
    - might want to somehow support this with annotations in the future

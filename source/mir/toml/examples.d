module mir.toml.examples;

import core.time;
import mir.toml;
import std.conv;

@safe
version(mir_toml_test) unittest
{
	import std.datetime.date;
	import std.datetime.systime;
	import std.datetime.timezone;
	import mir.algebraic;
	import mir.serde;

	alias StringOrDouble = Algebraic!(string, double);

	struct TempTargets
	{
		double cpu = 0;
		@serdeKeys("case")
		double case_ = 0;
	}

	struct Person
	{
		string name;
		@serdeKeys("dob")
		SysTime dayOfBirth;
	}

	struct Database
	{
		bool enabled;
		ushort[] ports;
		StringOrDouble[][] data;
		@tomlInlineTable
		@serdeKeys("temp_targets")
		TempTargets tempTargets;
	}

	struct Server
	{
		string ip;
		string role;
	}

	struct Servers
	{
		Server alpha;
		Server beta;
	}

	struct DocumentSample
	{
		string title;
		Person owner;
		Database database;
		Servers servers;
	}

	DocumentSample document = {
		title: "TOML Example",
		owner: Person(
			"Tom Preston-Werner",
			SysTime(DateTime(1979, 5, 27, 7, 32, 0), new immutable SimpleTimeZone(-8.hours))
		),
		database: Database(
			true,
			[8000, 8001, 8002]
		),
		servers: Servers(
			Server("10.0.0.1", "frontend"),
			Server("10.0.0.2", "backend"),
		)
	};
	document.database.data.length = 2;
	document.database.data[0] = [StringOrDouble("delta"), StringOrDouble("phi")];
	document.database.data[1] = [StringOrDouble(3.14)];
	document.database.tempTargets = TempTargets(79.5, 72.0);

	string serialized = serializeToml(document);
	assert(serialized == `title = "TOML Example"

[owner]
name = "Tom Preston-Werner"
dob = 1979-05-27T07:32:00-08:00

[database]
enabled = true
ports = [ 8000, 8001, 8002 ]
data = [ [ "delta", "phi" ], [ 3.14 ] ]
temp_targets = { cpu = 79.5, case = 72 }

[servers]
[servers.alpha]
ip = "10.0.0.1"
role = "frontend"

[servers.beta]
ip = "10.0.0.2"
role = "backend"
`);

	auto deserialized = deserializeToml!DocumentSample(serialized);
	assert(document == deserialized, text(document, " != ", deserialized));
}

unittest
{
	import mir.serde;
	import mir.algebraic;
	import std.datetime.date;

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

	debug { import std.stdio : writeln; writeln("minimal doc:\n", serializeToml(document, TOMLBeautyConfig.minify)); }
	debug { import std.stdio : writeln; writeln("doc:\n", serializeToml(document)); }
	debug { import std.stdio : writeln; writeln("pretty doc:\n", serializeToml(document, TOMLBeautyConfig.full)); }
}

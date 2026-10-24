// The Game Tools' view of a Godot 4 game, in the JSON protocol every OmniPlay state bridge speaks (RuntimeCore's
// StateWire): {op: "list", category: "store", query, offset, size} | {op: "get", target} | {op: "set", target,
// operation, value} | {op: "freeze", target, value} | {op: "unfreeze", target} | {op: "metadata"}; replies
// {entries, hasMore}, {old, effective}, {} or {error}.
//
// Targets are {kind: "path", root: "/root/Global", path: ["gold"]} (or ["stats", "hp"] into a Dictionary, Array or
// scripted Resource). Roots are /root's children (the autoloads and whatever the game parks there), then the current
// scene; each lists its script variables, exported or not. Only bool, int, float and text are edited, keeping their
// type. Main thread only: the host calls between two frames.
//
// Included by op_godot.mm (4.7) and Native/godot44/modules/omniplay/op_godot44.mm (4.4): the API it uses is the same in
// both. Godot 3 has its own copy (Native/godot3/modules/omniplay/op_godot3_state.inc).

#include "core/config/project_settings.h"
#include "core/io/json.h"
#include "core/io/resource.h"
#if __has_include("core/object/callable_mp.h")
#include "core/object/callable_mp.h" // 4.7
#else
#include "core/object/callable_method_pointer.h" // 4.4
#endif
#include "scene/main/scene_tree.h"
#include "scene/main/window.h"

#include <cmath>

namespace op_state {

static const int MAX_FROZEN = 32;
// shortcut: a container shows its first 256 children only; page them if a game keeps bigger ones worth editing.
static const int MAX_CHILDREN = 256;

struct Frozen {
	String root;
	Array path;
	Variant value;
};
static Vector<Frozen> frozen;

static SceneTree *tree() { return Object::cast_to<SceneTree>(OS::get_singleton()->get_main_loop()); }

static bool is_leaf(const Variant &v) {
	switch (v.get_type()) {
	case Variant::BOOL:
	case Variant::INT:
	case Variant::STRING:
	case Variant::STRING_NAME: return true;
	case Variant::FLOAT: return std::isfinite(double(v)); // JSON has no inf or nan
	default: return false;
	}
}

static Object *scripted_resource(const Variant &v) {
	if (v.get_type() != Variant::OBJECT)
		return nullptr;
	Resource *r = Object::cast_to<Resource>(v.get_validated_object());
	return r && r->get_script_instance() ? r : nullptr;
}

static bool is_container(const Variant &v) {
	return v.get_type() == Variant::DICTIONARY || v.get_type() == Variant::ARRAY || scripted_resource(v);
}

static String type_name(const Variant &v) {
	if (v.get_type() == Variant::OBJECT) {
		Object *o = v.get_validated_object();
		return o ? String(o->get_class()) : String("Freed object");
	}
	return Variant::get_type_name(v.get_type());
}

// An object's script variables (GDScript members, exported or not; compiled scripts too), in declaration order.
static Vector<StringName> script_names(Object *o) {
	Vector<StringName> out;
	List<PropertyInfo> list;
	o->get_property_list(&list);
	for (const PropertyInfo &p : list) {
		if ((p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) && !(p.usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP)))
			out.push_back(p.name);
	}
	return out;
}

// A value as plain JSON data, containers `depth` levels deep; anything past that, or not data, as "<Type>".
static Variant plain(const Variant &v, int depth) {
	if (is_leaf(v))
		return v.get_type() == Variant::STRING_NAME ? Variant(String(v)) : v;
	if (v.get_type() == Variant::NIL)
		return v;
	if (depth > 0 && v.get_type() == Variant::DICTIONARY) {
		Dictionary d = v, out;
		Array keys = d.keys();
		for (int i = 0; i < MIN(keys.size(), MAX_CHILDREN); i++)
			out[String(keys[i])] = plain(d[keys[i]], depth - 1);
		return out;
	}
	if (depth > 0 && v.get_type() == Variant::ARRAY) {
		Array a = v, out;
		for (int i = 0; i < MIN(a.size(), MAX_CHILDREN); i++)
			out.push_back(plain(a[i], depth - 1));
		return out;
	}
	if (Object *o = depth > 0 ? scripted_resource(v) : nullptr) {
		Dictionary out;
		for (const StringName &n : script_names(o))
			out[String(n)] = plain(o->get(n), depth - 1);
		return out;
	}
	return "<" + type_name(v) + ">";
}

static Dictionary entry(const String &root, const Array &path, const String &name, const Variant &v) {
	Dictionary target, e;
	target["kind"] = "path";
	target["root"] = root;
	target["path"] = path;
	e["target"] = target;
	e["name"] = name;
	if (is_leaf(v) || v.get_type() == Variant::NIL || is_container(v)) {
		e["value"] = plain(v, 2);
		e["editable"] = is_leaf(v);
	} else {
		e["value"] = Variant();
		e["objectType"] = type_name(v);
		e["summary"] = String(v).left(200);
		e["editable"] = false;
	}
	return e;
}

// /root's children, then the current scene.
static Vector<Node *> roots() {
	Vector<Node *> out;
	Window *root = tree()->get_root();
	Node *scene = tree()->get_current_scene();
	for (int i = 0; i < root->get_child_count(false); i++) {
		Node *child = root->get_child(i, false);
		if (child != scene)
			out.push_back(child);
	}
	if (scene)
		out.push_back(scene);
	return out;
}

// One step down: a Dictionary key (matched as text), an Array index or an object's property.
static bool step(const Variant &c, const String &key, Variant &out) {
	if (c.get_type() == Variant::DICTIONARY) {
		Dictionary d = c;
		Array keys = d.keys();
		for (int i = 0; i < keys.size(); i++) {
			if (String(keys[i]) == key) {
				out = d[keys[i]];
				return true;
			}
		}
		return false;
	}
	if (c.get_type() == Variant::ARRAY) {
		Array a = c;
		int i = key.to_int();
		if (!key.is_valid_int() || i < 0 || i >= a.size())
			return false;
		out = a[i];
		return true;
	}
	Object *o = c.get_type() == Variant::OBJECT ? c.get_validated_object() : nullptr;
	if (!o)
		return false;
	bool valid = false;
	out = o->get(StringName(key), &valid);
	return valid;
}

static bool assign(const Variant &c, const String &key, const Variant &value) {
	if (c.get_type() == Variant::DICTIONARY) {
		Dictionary d = c; // shares the game's dictionary
		Array keys = d.keys();
		for (int i = 0; i < keys.size(); i++) {
			if (String(keys[i]) == key) {
				d[keys[i]] = value;
				return true;
			}
		}
		return false;
	}
	if (c.get_type() == Variant::ARRAY) {
		Array a = c; // shares the game's array
		int i = key.to_int();
		if (!key.is_valid_int() || i < 0 || i >= a.size())
			return false;
		a.set(i, value);
		return true;
	}
	Object *o = c.get_type() == Variant::OBJECT ? c.get_validated_object() : nullptr;
	if (!o)
		return false;
	bool valid = false;
	o->set(StringName(key), value, &valid); // through the script's setter, as the game would
	return valid;
}

// The container that holds the target's last key; false once the node or a step along the path is gone.
static bool resolve(const String &root, const Array &path, Variant &parent, String &key) {
	if (path.is_empty())
		return false;
	Node *node = tree()->get_root()->get_node_or_null(NodePath(root));
	if (!node)
		return false;
	Variant at = node;
	for (int i = 0; i < path.size() - 1; i++) {
		if (!step(at, String(path[i]), at))
			return false;
	}
	parent = at;
	key = String(path[path.size() - 1]);
	return true;
}

static bool number(const Variant &v) { return v.get_type() == Variant::INT || v.get_type() == Variant::FLOAT; }

// The requested value in the old value's own type; false for anything but plain values.
static bool coerce(const Variant &old, const Variant &v, const String &op, Variant &out) {
	switch (old.get_type()) {
	case Variant::BOOL:
		if (op == "toggle")
			out = !bool(old);
		else if (v.get_type() == Variant::BOOL || number(v))
			out = bool(v);
		else
			return false;
		return true;
	case Variant::INT:
		if (!number(v))
			return false;
		out = (op == "add" ? int64_t(old) : 0) + int64_t(double(v));
		return true;
	case Variant::FLOAT:
		if (!number(v) || !std::isfinite(double(v)))
			return false;
		out = (op == "add" ? double(old) : 0.0) + double(v);
		return true;
	case Variant::STRING:
	case Variant::STRING_NAME:
		if (v.get_type() != Variant::STRING)
			return false;
		out = old.get_type() == Variant::STRING_NAME ? Variant(StringName(String(v))) : v;
		return true;
	default: return false;
	}
}

static Dictionary failure(const String &message) {
	Dictionary d;
	d["error"] = message;
	return d;
}

static Dictionary write(const Dictionary &target, const String &op, const Variant &value) {
	Variant parent, old, now;
	String key;
	if (!resolve(target.get("root", ""), target.get("path", Array()), parent, key) || !step(parent, key, old))
		return failure("The game no longer has this value.");
	Variant wanted;
	if (!is_leaf(old) || !coerce(old, value, op, wanted))
		return failure("Only plain values can be edited.");
	if (!assign(parent, key, wanted) || !step(parent, key, now))
		return failure("The game refused the change.");
	Dictionary reply;
	reply["old"] = plain(old, 0);
	reply["effective"] = plain(now, 0);
	reply["persistent"] = false;
	return reply;
}

static int frozen_index(const Dictionary &target) {
	for (int i = 0; i < frozen.size(); i++) {
		if (frozen[i].root == String(target.get("root", "")) && frozen[i].path == Array(target.get("path", Array())))
			return i;
	}
	return -1;
}

// Every frame: frozen values the game changed go back; a value whose node or path is gone stops being held.
static void reapply() {
	for (int i = frozen.size() - 1; i >= 0; i--) {
		Variant parent, now;
		String key;
		const Frozen &f = frozen[i];
		bool ok = resolve(f.root, f.path, parent, key) && step(parent, key, now);
		if (ok && now != f.value)
			ok = assign(parent, key, f.value);
		if (!ok)
			frozen.remove_at(i);
	}
	if (frozen.is_empty() && tree() && tree()->is_connected(SNAME("process_frame"), callable_mp_static(&reapply)))
		tree()->disconnect(SNAME("process_frame"), callable_mp_static(&reapply));
}

static Dictionary freeze(const Dictionary &target, const Variant &value) {
	int at = frozen_index(target);
	if (at < 0 && frozen.size() >= MAX_FROZEN)
		return failure(vformat("At most %d values can be frozen.", MAX_FROZEN));
	Dictionary reply = write(target, "set", value);
	if (reply.has("error"))
		return reply;
	// Held at what the game accepted, in the variable's own type, so the hold never fights the game.
	Variant parent, held;
	String key;
	resolve(target["root"], target["path"], parent, key);
	step(parent, key, held);
	if (at >= 0)
		frozen.write[at].value = held;
	else
		frozen.push_back({ target["root"], target["path"], held });
	if (!tree()->is_connected(SNAME("process_frame"), callable_mp_static(&reapply)))
		tree()->connect(SNAME("process_frame"), callable_mp_static(&reapply));
	return reply;
}

static Dictionary list(const String &category, const String &query, int offset, int size) {
	if (category != "store")
		return failure("category not available here: " + category);
	struct Found {
		Node *node;
		StringName name;
		String label;
	};
	Vector<Found> found;
	String q = query.to_lower();
	for (Node *node : roots()) {
		for (const StringName &n : script_names(node)) {
			String label = String(node->get_name()) + "." + String(n);
			if (q.is_empty() || label.to_lower().contains(q))
				found.push_back({ node, n, label });
		}
	}
	Array entries;
	for (int i = MAX(offset, 0); i < MIN(found.size(), offset + size); i++) {
		Array path;
		path.push_back(String(found[i].name));
		entries.push_back(entry(String(found[i].node->get_path()), path, found[i].label, found[i].node->get(found[i].name)));
	}
	Dictionary reply;
	reply["entries"] = entries;
	reply["hasMore"] = offset + size < found.size();
	return reply;
}

static Dictionary get(const Dictionary &target) {
	Variant parent, value;
	String key;
	if (!resolve(target.get("root", ""), target.get("path", Array()), parent, key) || !step(parent, key, value))
		return failure("The game no longer has this value.");
	Array entries;
	entries.push_back(entry(target["root"], target["path"], "", value));
	Dictionary reply;
	reply["entries"] = entries;
	reply["hasMore"] = false;
	return reply;
}

static Dictionary handle(const Dictionary &request) {
	String op = request.get("op", "");
	Dictionary target = request.get("target", Dictionary());
	if (op == "list")
		return list(request.get("category", ""), request.get("query", ""), int(request.get("offset", 0)), int(request.get("size", 200)));
	if (op == "get")
		return get(target);
	if (op == "set")
		return write(target, request.get("operation", "set"), request.get("value", Variant()));
	if (op == "freeze")
		return freeze(target, request.get("value", Variant()));
	if (op == "unfreeze") {
		int at = frozen_index(target);
		if (at >= 0)
			frozen.remove_at(at);
		return Dictionary();
	}
	if (op == "metadata") {
		Dictionary reply;
		reply["name"] = ProjectSettings::get_singleton()->get_setting("application/config/name", "");
		return reply;
	}
	return failure("unknown op " + op);
}

// JSON text in, JSON text out (malloc'd, for the host to free); never fails, an error is a reply.
static char *reply(const char *request, bool in_game) {
	Variant parsed = JSON::parse_string(String::utf8(request ? request : ""));
	Dictionary out;
	if (parsed.get_type() != Variant::DICTIONARY)
		out = failure("unreadable request");
	else if (!in_game || !tree() || !tree()->get_root())
		out = failure("notInGame");
	else
		out = handle(parsed);
	return strdup(JSON::stringify(out).utf8().get_data());
}

} // namespace op_state

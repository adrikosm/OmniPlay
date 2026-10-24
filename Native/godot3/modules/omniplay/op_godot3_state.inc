// The Game Tools' view of a Godot 3 game: Native/godot/modules/omniplay/op_godot_state.inc (Godot 4) in Godot 3's API,
// the same protocol and the same behaviour. Godot 3 has no StringName variant and no callables, so freezes are held
// from a small registered object connected to SceneTree's idle_frame. Included by op_godot3.mm. Main thread only.

#include "core/class_db.h"
#include "core/io/json.h"
#include "core/project_settings.h"
#include "core/resource.h"
#include "scene/main/scene_tree.h"
#include "scene/main/viewport.h"

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
static void reapply();

} // namespace op_state

// Godot 3 connects signals to an object's bound method only.
class OmniPlayFreezer : public Object {
	GDCLASS(OmniPlayFreezer, Object);

protected:
	static void _bind_methods() { ClassDB::bind_method(D_METHOD("_reapply"), &OmniPlayFreezer::_reapply); }

public:
	void _reapply() { op_state::reapply(); }
};

namespace op_state {

static SceneTree *tree() { return Object::cast_to<SceneTree>(OS::get_singleton()->get_main_loop()); }

// Registered on first use and kept for the process: one game per process.
static OmniPlayFreezer *freezer() {
	static OmniPlayFreezer *f = nullptr;
	if (!f) {
		ClassDB::register_class<OmniPlayFreezer>();
		f = memnew(OmniPlayFreezer);
	}
	return f;
}

static bool is_leaf(const Variant &v) {
	switch (v.get_type()) {
	case Variant::BOOL:
	case Variant::INT:
	case Variant::STRING: return true;
	case Variant::REAL: return std::isfinite(double(v)); // JSON has no inf or nan
	default: return false;
	}
}

static Object *object(const Variant &v) { return v.get_type() == Variant::OBJECT ? v.operator Object *() : nullptr; }

static Object *scripted_resource(const Variant &v) {
	Resource *r = Object::cast_to<Resource>(object(v));
	return r && r->get_script_instance() ? r : nullptr;
}

static bool is_container(const Variant &v) {
	return v.get_type() == Variant::DICTIONARY || v.get_type() == Variant::ARRAY || scripted_resource(v);
}

static String type_name(const Variant &v) {
	if (v.get_type() == Variant::OBJECT) {
		Object *o = object(v);
		return o ? o->get_class() : String("Freed object");
	}
	return Variant::get_type_name(v.get_type());
}

static Vector<StringName> script_names(Object *o) {
	Vector<StringName> out;
	List<PropertyInfo> list;
	o->get_property_list(&list);
	for (const List<PropertyInfo>::Element *E = list.front(); E; E = E->next()) {
		const PropertyInfo &p = E->get();
		if ((p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) && !(p.usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP)))
			out.push_back(p.name);
	}
	return out;
}

static Variant plain(const Variant &v, int depth) {
	if (is_leaf(v) || v.get_type() == Variant::NIL)
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
		Vector<StringName> names = script_names(o);
		for (int i = 0; i < names.size(); i++)
			out[String(names[i])] = plain(o->get(names[i]), depth - 1);
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

static Vector<Node *> roots() {
	Vector<Node *> out;
	Viewport *root = tree()->get_root();
	Node *scene = tree()->get_current_scene();
	for (int i = 0; i < root->get_child_count(); i++) {
		Node *child = root->get_child(i);
		if (child != scene)
			out.push_back(child);
	}
	if (scene)
		out.push_back(scene);
	return out;
}

static bool index(const Array &a, const String &key, int &i) {
	i = key.to_int();
	return key.is_valid_integer() && i >= 0 && i < a.size();
}

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
		int i;
		if (!index(a, key, i))
			return false;
		out = a[i];
		return true;
	}
	Object *o = object(c);
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
		int i;
		if (!index(a, key, i))
			return false;
		a.set(i, value);
		return true;
	}
	Object *o = object(c);
	if (!o)
		return false;
	bool valid = false;
	o->set(StringName(key), value, &valid); // through the script's setter, as the game would
	return valid;
}

static bool resolve(const String &root, const Array &path, Variant &parent, String &key) {
	if (path.empty())
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

static bool number(const Variant &v) { return v.get_type() == Variant::INT || v.get_type() == Variant::REAL; }

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
	case Variant::REAL:
		if (!number(v) || !std::isfinite(double(v)))
			return false;
		out = (op == "add" ? double(old) : 0.0) + double(v);
		return true;
	case Variant::STRING:
		if (v.get_type() != Variant::STRING)
			return false;
		out = v;
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

static void reapply() {
	for (int i = frozen.size() - 1; i >= 0; i--) {
		Variant parent, now;
		String key;
		const Frozen &f = frozen[i];
		bool ok = resolve(f.root, f.path, parent, key) && step(parent, key, now);
		if (ok && now != f.value)
			ok = assign(parent, key, f.value);
		if (!ok)
			frozen.remove(i);
	}
	if (frozen.empty() && tree() && tree()->is_connected("idle_frame", freezer(), "_reapply"))
		tree()->disconnect("idle_frame", freezer(), "_reapply");
}

static Dictionary freeze(const Dictionary &target, const Variant &value) {
	int at = frozen_index(target);
	if (at < 0 && frozen.size() >= MAX_FROZEN)
		return failure(vformat("At most %d values can be frozen.", MAX_FROZEN));
	Dictionary reply = write(target, "set", value);
	if (reply.has("error"))
		return reply;
	Variant parent, held;
	String key;
	resolve(target["root"], target["path"], parent, key);
	step(parent, key, held);
	if (at >= 0) {
		frozen.write[at].value = held;
	} else {
		Frozen f = { target["root"], target["path"], held };
		frozen.push_back(f);
	}
	if (!tree()->is_connected("idle_frame", freezer(), "_reapply"))
		tree()->connect("idle_frame", freezer(), "_reapply");
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
	Vector<Node *> nodes = roots();
	for (int r = 0; r < nodes.size(); r++) {
		Vector<StringName> names = script_names(nodes[r]);
		for (int i = 0; i < names.size(); i++) {
			String label = String(nodes[r]->get_name()) + "." + String(names[i]);
			if (q.empty() || label.to_lower().find(q) >= 0) {
				Found f = { nodes[r], names[i], label };
				found.push_back(f);
			}
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
			frozen.remove(at);
		return Dictionary();
	}
	if (op == "metadata") {
		Dictionary reply;
		ProjectSettings *settings = ProjectSettings::get_singleton();
		reply["name"] = settings->has_setting("application/config/name") ? settings->get_setting("application/config/name") : Variant("");
		return reply;
	}
	return failure("unknown op " + op);
}

static char *reply(const char *request, bool in_game) {
	Variant parsed;
	String error;
	int line = 0;
	Dictionary out;
	if (JSON::parse(String::utf8(request ? request : ""), parsed, error, line) != OK || parsed.get_type() != Variant::DICTIONARY)
		out = failure("unreadable request");
	else if (!in_game || !tree() || !tree()->get_root())
		out = failure("notInGame");
	else
		out = handle(parsed);
	return strdup(JSON::print(out).utf8().get_data());
}

} // namespace op_state

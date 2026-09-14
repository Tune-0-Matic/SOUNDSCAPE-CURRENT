/**************************************************************************/
/*  register_types.cpp                                                    */
/*  Extension entry point. Everything the engine knows about us is here.   */
/**************************************************************************/

#include "register_types.h"

#include "ss_effect.h"
#include "ss_flac.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_soundscape_dsp(ModuleInitializationLevel p_level) {
	// SCENE is the level AudioEffect and its friends exist at. Registering earlier
	// means registering against a ClassDB that has not seen our base class yet.
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	// Order matters: the instance type must exist before the resource that returns it
	// from _instantiate, or the return type cannot be resolved.
	GDREGISTER_CLASS(SsEffectInstance);
	GDREGISTER_CLASS(SsEffect);
	GDREGISTER_CLASS(SsFlacPlayback);
	GDREGISTER_CLASS(SsFlacStream);
}

void uninitialize_soundscape_dsp(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	// Nothing to tear down: every SharedState is owned by its SsEffect's shared_ptr
	// and dies with it. There is no global state in this extension, deliberately --
	// a static that outlives the engine's audio server is a shutdown crash waiting
	// for a user to close the program while a track is playing.
}

extern "C" {
// The symbol named by soundscape.gdextension's `entry_symbol`. If these two ever
// disagree the library loads and then silently registers nothing, which presents as
// "SsEffect does not exist" with no error anywhere -- so they are checked by
// test_ss_effect.gd rather than trusted.
GDExtensionBool GDE_EXPORT soundscape_dsp_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_soundscape_dsp);
	init_obj.register_terminator(uninitialize_soundscape_dsp);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}

/**************************************************************************/
/*  register_types.cpp                                                    */
/*  Extension entry point. Everything the engine knows about us is here.   */
/**************************************************************************/

#include "register_types.h"

#include "ss_casual.h"
#include "ss_dsd.h"
#include "ss_effect.h"
#include "ss_flac.h"
#include "ss_parallel.h"
#include "ss_wav.h"

#include <gdextension_interface.h>
#include <godot_cpp/classes/audio_server.hpp>
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
	GDREGISTER_CLASS(SsWavPlayback);
	GDREGISTER_CLASS(SsWavStream);
	GDREGISTER_CLASS(SsDsdPlayback);
	GDREGISTER_CLASS(SsDsdStream);
	GDREGISTER_CLASS(SsParallelInstance);
	GDREGISTER_CLASS(SsParallel);
	GDREGISTER_CLASS(SsCasualCurveInstance);
	GDREGISTER_CLASS(SsCasualCurve);
}

void uninitialize_soundscape_dsp(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	// Every SharedState is owned by its effect's shared_ptr and dies with it. There is no global state
	// in this extension, deliberately -- a static that outlives the engine's audio server is a
	// shutdown crash waiting for a user to close the program while a track is playing.
	//
	// But the EFFECTS can outlive us. Godot 4.7's Main::cleanup deinitializes extensions at this level
	// BEFORE audio_server->finish() frees the buses, so an SsParallel, SsCasualCurve or SsEffect still
	// on a bus at quit was destroyed after its class had been unregistered -- a dangling pointer that
	// crashed about one exit in ten (measured 2026-09-16 with the CASUAL curve left on Master). The
	// server is still alive here, so every effect of ours comes off every bus now, while its class exists.
	AudioServer *server = AudioServer::get_singleton();
	if (server == nullptr) {
		return;
	}
	for (int32_t bus = server->get_bus_count() - 1; bus >= 0; --bus) {
		for (int32_t i = server->get_bus_effect_count(bus) - 1; i >= 0; --i) {
			const Ref<AudioEffect> effect = server->get_bus_effect(bus, i);
			if (Object::cast_to<SsParallel>(effect.ptr()) || Object::cast_to<SsCasualCurve>(effect.ptr())
					|| Object::cast_to<SsEffect>(effect.ptr())) {
				server->remove_bus_effect(bus, i);
			}
		}
	}
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

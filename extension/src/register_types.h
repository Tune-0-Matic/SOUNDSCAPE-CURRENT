/**************************************************************************/
/*  register_types.h                                                      */
/**************************************************************************/

#ifndef SOUNDSCAPE_REGISTER_TYPES_H
#define SOUNDSCAPE_REGISTER_TYPES_H

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_soundscape_dsp(ModuleInitializationLevel p_level);
void uninitialize_soundscape_dsp(ModuleInitializationLevel p_level);

#endif // SOUNDSCAPE_REGISTER_TYPES_H

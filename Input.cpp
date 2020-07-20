#include "Input.h"

#include <cstring>

#define KEY_TABLE_SIZE SDL_NUM_SCANCODES

static bool keyboard_state_previous_frame[KEY_TABLE_SIZE] = { };

void Input::update() {
	// Save current Keyboard State
	memcpy(keyboard_state_previous_frame, SDL_GetKeyboardState(nullptr), KEY_TABLE_SIZE);
}

bool Input::is_key_down(SDL_Scancode key) {
	return SDL_GetKeyboardState(nullptr)[int(key)];
}

bool Input::is_key_up(SDL_Scancode key) {
	return !SDL_GetKeyboardState(nullptr)[int(key)];
}

bool Input::is_key_pressed(SDL_Scancode key) {
	return SDL_GetKeyboardState(nullptr)[int(key)] && !keyboard_state_previous_frame[int(key)];
}

bool Input::is_key_released(SDL_Scancode key) {
	return !SDL_GetKeyboardState(nullptr)[int(key)] && keyboard_state_previous_frame[int(key)];
}
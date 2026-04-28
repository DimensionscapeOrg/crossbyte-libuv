#pragma once

#include <hxcpp.h>

Dynamic crossbyte_libuv_poll_create(int capacity);
void crossbyte_libuv_poll_prepare(Dynamic handle, Array<Dynamic> read, Array<Dynamic> write);
Array<Dynamic> crossbyte_libuv_poll_events(Dynamic handle, double timeout);
void crossbyte_libuv_poll_dispose(Dynamic handle);

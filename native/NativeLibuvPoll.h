#pragma once

Dynamic crossbyte_libuv_poll_create(int capacity);
Array<Dynamic> crossbyte_libuv_poll_prepare(Dynamic handle, Array<Dynamic> read, Array<Dynamic> write);
void crossbyte_libuv_poll_events(Dynamic handle, double timeout);
void crossbyte_libuv_poll_remove(Dynamic handle, Dynamic socket);
Array<int> crossbyte_libuv_poll_stats(Dynamic handle);
void crossbyte_libuv_poll_dispose(Dynamic handle);

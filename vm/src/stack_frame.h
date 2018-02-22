#ifndef STACK_FRAME_H
#define STACK_FRAME_H

#include "sizes.h"

struct Virtual_Thread;

struct Stack_Frame {
	struct Virtual_Thread* parent_thread;
	struct Stack_Frame* parent;

	uint8_t locals[LOCALS_SIZE];

	size_t local_index;
	size_t return_addr;
};

#endif
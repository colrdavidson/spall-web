
/* TODO

    enum { RING_BUFFER_SIZE = 65536 };
    struct Event {
        uintptr_t is_end; // same size as const char* to avoid padding bytes
        const char *name;
        double when;
    };
    struct RegisteredThread {
        uint32_t pid;
        uint32_t tid;
        _Atomic uint64_t read_head;
        _Atomic uint64_t write_head;
#ifdef DYNAMIC_STRINGS
        void *allocator_userdata;
#endif
        Event events[RING_BUFFER_SIZE];
    };
    struct ProfileContext {
        Semaphore recording;
        Semaphore any_thread_has_written;
        bool never_drop_events;
        Mutex mutex; {
            RegisteredThread **registered_threads;
            int n_threads;
            SpallContext ctx;
        }
    };

    ProfileContext profile_init(, bool start_recording) {
        
    }

    void output_profile(ProfileContext *profile) {
        mutex_lock(&profile->mutex); {
            for (auto &thread : registered_threads) {
                if (thread.read_head <= thread.write_head - (RING_BUFFER_SIZE - 1)) {
                    printf(!"Ring tear. Increase the ring buffer size! :(");
                    SpallTraceBeginTidPid(&profile->ctx, "Ring tear. Increase the ring buffer size! :(", event.when, thread.tid, thread.pid);
                    thread.read_head = 0xffffffffffffffffull;
                    continue; // TODO: depth recovery
                }
                while (thread.read_head < thread.write_head) {
                    Event event = thread.events[thread.read_head & (RING_BUFFER_SIZE - 1)];
                    if (!event.is_end) {
                        SpallTraceBeginTidPid(&profile->ctx, event.name, event.when, thread.tid, thread.pid);
                    } else {
                        SpallTraceEndTidPid(&profile->ctx, event.when, thread.tid, thread.pid);
                    }
                    ++thread.read_head; // atomic
                }
            }
        }
        mutex_unlock(&profile->mutex);
        SpallFlush();
    }

    int output_thread(void *userdata) {
        ProfileContext *profile = (ProfileContext *)userdata;
        while (true) {
            wait_for_semaphore_forever(profile->recording);
            wait_for_semaphore_forever(profile->any_thread_has_written);
            output_profile(profile);
        }
    }

    // note: /Ob1 is how you would get FORCE_INLINE to work on msvc in debug mode
    inline void trace_begin(ProfileContext *profile, RegisteredThread *thread, const char *name) {
        if (UNLIKELY(profile->never_drop_events & profile->recording)) { // note: bitwise and could reduce branch predict slots?
            if (UNLIKELY(thread.read_head <= thread.write_head - (RING_BUFFER_SIZE - 1))) {
                output_profile(profile);
            }
        }
        Event *event = &thread->events[thread->write_head & (RING_BUFFER_SIZE - 1)];
#ifdef DYNAMIC_STRINGS
        if (LIKELY(event->name)) SPALL_FREE(event->name, thread->allocator_userdata);
        name = SPALL_STRDUP(name, thread->allocator_userdata);
#endif
        *event = { false, thread->thread_depth++, name, __rdtsc() };
        ++thread->write_head; // atomic
        signal_semaphore(profile->any_thread_has_written);
    }
    inline void trace_end(ProfileContext *profile, RegisteredThread *thread, EventID id) {
        Event *event = &thread->events[thread->write_head & (RING_BUFFER_SIZE - 1)];
        thread->events[thread->write_head & (RING_BUFFER_SIZE - 1)] = { true, id, thread->events[thread->write_head & (RING_BUFFER_SIZE - 1)].name, __rdtsc() };
        ++thread->write_head; // atomic
        signal_semaphore(profile->any_thread_has_written);
    }

    RegisteredThread *thread_init(ProfileContext *profile, u32 pid, u32 tid, u8 ring_buffer_size_power) {
        // handle = CreateSemaphoreA()
        RegisteredThread *result = array_calloc_and_append(&profile->registered_threads, &profile->n_threads);
    }
    void thread_quit(RegisteredThread *thread) {
        output_profile(profile);
        array_remove_unordered_and_free(&profile->registered_threads, thread);
    }
*/

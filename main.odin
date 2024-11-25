package main

import "core:fmt"
import "core:os"
import "core:log"
import "core:mem"
import "core:time"
import "core:strconv"
import "core:c"

import sdl "vendor:sdl2"

import "assets"

AlarmSchedule :: struct {
    hour: int,
    min: int,
}

alarm_schedule_from_env :: proc() -> AlarmSchedule {
    schedule: AlarmSchedule
    bad_config := false

    //TODO use this instead: `n, ok := strconv.parse_u64_of_base("1234e3", 10)`

    hour_str := os.get_env("HOUR")
    if hour_str == "" {
        log.error("HOUR environment variable cannot be empty")
        bad_config = true
    } else {
        schedule.hour = strconv.atoi(hour_str)
        fmt.println(schedule.hour)
    }

    min_str := os.get_env("MIN")
    if min_str == "" {
        log.error("MIN environment variable cannot be empty")
        bad_config = true
    } else {
        schedule.min = strconv.atoi(min_str)
    }

    if bad_config {
        log.error("bad config")
        os.exit(1)
    }

    return schedule
}

main :: proc() {
    when ODIN_DEBUG {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        context.allocator = mem.tracking_allocator(&track)
        defer {
            if len(track.allocation_map) > 0 {
                fmt.eprintf("\n=== %v allocations not freed: ===\n", len(track.allocation_map))
                for _, entry in track.allocation_map {
                    fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
                }
            }
            if len(track.bad_free_array) > 0 {
                fmt.eprintf("\n=== %v incorrect frees: ===\n", len(track.bad_free_array))
                for entry in track.bad_free_array {
                    fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
                }
            }
            mem.tracking_allocator_destroy(&track)
        }
    }
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    run()
}

run :: proc() {
    log.info("setup...")

    //TODO get this also interactively 
    alarm_schedule := alarm_schedule_from_env()

    if rc := sdl.Init({ .AUDIO }); rc != 0 {
        log.error("failed to init sdl: %s", sdl.GetError())
        os.exit(1)
    }
    defer sdl.Quit()

    // wait for it...
    log.info("waiting for the clock...")
    for {
        now := time.now()
        hour, min, _ := time.clock_from_time(now)
        //NOTE: hour is in UTC-0
        if (alarm_schedule.hour + 3) % 24 == hour && alarm_schedule.min == min {
            break
        }
        sdl.Delay(1000)
    }
    log.info("time's up!")

    // create RW I/O interface from the audio buffer
    asset_rwops := sdl.RWFromConstMem(raw_data(assets.ABESTADO_SELIGAI_WAV), assets.ABESTADO_SELIGAI_WAV_LEN)
    defer sdl.RWclose(asset_rwops)

    // parses the audio into spec
    spec: sdl.AudioSpec
    buf: [^]u8
    buf_len: u32
    if sdl.LoadWAV_RW(asset_rwops, false, &spec, &buf, &buf_len) == nil {
        log.error("failed to load wav sound: %s", sdl.GetError())
        os.exit(1)
    }
    defer sdl.FreeWAV(buf)
    assert(buf != nil)
    assert(buf_len > 0)
    
    device_id: sdl.AudioDeviceID = sdl.OpenAudioDevice(nil, false, &spec, nil, false)
    defer sdl.CloseAudioDevice(device_id)

    if rc := sdl.QueueAudio(device_id, buf, buf_len); rc != 0 {
        log.error("failed to queue audio: %s", sdl.GetError())
        os.exit(1)
    }

    sdl.PauseAudioDevice(device_id, false);

    // waits for the finish of the audio
    for remaining := sdl.GetQueuedAudioSize(device_id); remaining > 0; remaining = sdl.GetQueuedAudioSize(device_id) {
        sdl.Delay(100)
    }
}

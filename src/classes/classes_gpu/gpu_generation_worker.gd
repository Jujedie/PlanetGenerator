extends RefCounted
class_name GPUGenerationWorker

## Single persistent worker thread dedicated to Planet Generator's local
## RenderingDevice. All monolithic GPU work is serialized here so the scene
## tree/main thread stays responsive and the shared local RD is always used
## from the same OS thread.

static var _runner: GPUGenerationWorker = null
static var _thread: Thread = null
static var _mutex: Mutex = Mutex.new()
static var _semaphore: Semaphore = Semaphore.new()
static var _jobs: Array[Callable] = []
static var _stop_requested: bool = false
static var _accepting_jobs: bool = true


static func submit(job: Callable) -> bool:
	if not job.is_valid():
		return false
	_mutex.lock()
	if not _accepting_jobs:
		_mutex.unlock()
		return false
	var needs_start := _thread == null
	if needs_start:
		_runner = GPUGenerationWorker.new()
		_thread = Thread.new()
		_stop_requested = false
		var err := _thread.start(_runner._worker_loop)
		if err != OK:
			_thread = null
			_runner = null
			_mutex.unlock()
			push_error("[GPUGenerationWorker] Unable to start background GPU worker: %s" % err)
			return false
	_jobs.append(job)
	_mutex.unlock()
	_semaphore.post()
	return true


static func shutdown() -> void:
	_mutex.lock()
	if _thread == null:
		_accepting_jobs = true
		_stop_requested = false
		_jobs.clear()
		_mutex.unlock()
		return
	_accepting_jobs = false
	_stop_requested = true
	_mutex.unlock()
	# One extra token lets the loop observe the stop request after all queued
	# jobs (each of which already owns one semaphore token) have drained.
	_semaphore.post()
	if _thread.is_started():
		_thread.wait_to_finish()
	_mutex.lock()
	_thread = null
	_runner = null
	_jobs.clear()
	_stop_requested = false
	_accepting_jobs = true
	_mutex.unlock()


func _worker_loop() -> void:
	while true:
		_semaphore.wait()
		var job := Callable()
		var should_stop := false
		_mutex.lock()
		if not _jobs.is_empty():
			job = _jobs.pop_front()
		elif _stop_requested:
			should_stop = true
		_mutex.unlock()

		if job.is_valid():
			job.call()
		if should_stop:
			break

	# The shared local RenderingDevice was created and used on this thread;
	# destroy it here as well to keep thread ownership consistent.
	GPUContext.shutdown_shared_device()

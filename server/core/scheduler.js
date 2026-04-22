const moment = require('moment')
const { Worker } = require('worker_threads')
const path = require('path')
const _ = require('lodash')
const configHelper = require('../helpers/config')

/* global WIKI */

class ThreadPool {
  constructor(size) {
    this.size = size
    this.workers = []
    this.idle = []
    this.queue = []
    this.jobCounter = 0
    this.pending = new Map()
  }

  start() {
    for (let i = 0; i < this.size; i++) {
      this._spawnWorker()
    }
  }

  _spawnWorker() {
    const worker = new Worker(path.join(WIKI.SERVERPATH, 'core/worker-thread.js'))
    worker.once('message', (msg) => {
      if (msg.ready) {
        this.idle.push(worker)
        this._drain()
      }
    })
    worker.on('message', (msg) => {
      if (msg.ready) return
      const { resolve, reject } = this.pending.get(msg.jobId) || {}
      this.pending.delete(msg.jobId)
      this.idle.push(worker)
      this._drain()
      if (!resolve) return
      if (msg.ok) {
        resolve()
      } else {
        reject(new Error(msg.error))
      }
    })
    worker.on('error', (err) => {
      WIKI.logger.error(`(SCHEDULER) Thread pool worker error: ${err.message}`)
      // replace the dead worker
      this.workers = this.workers.filter(w => w !== worker)
      this._spawnWorker()
    })
    this.workers.push(worker)
  }

  _drain() {
    if (this.queue.length === 0 || this.idle.length === 0) return
    const { jobId, job, data, resolve, reject } = this.queue.shift()
    const worker = this.idle.pop()
    this.pending.set(jobId, { resolve, reject })
    worker.postMessage({ jobId, job, data })
  }

  run(job, data) {
    return new Promise((resolve, reject) => {
      const jobId = ++this.jobCounter
      this.queue.push({ jobId, job, data, resolve, reject })
      this._drain()
    })
  }

  async stop() {
    await Promise.all(this.workers.map(w => w.terminate()))
    this.workers = []
    this.idle = []
  }
}

class Job {
  constructor({
    name,
    immediate = false,
    schedule = 'P1D',
    repeat = false,
    worker = false
  }, queue) {
    this.queue = queue
    this.finished = Promise.resolve()
    this.name = name
    this.immediate = immediate
    this.schedule = moment.duration(schedule)
    this.repeat = repeat
    this.worker = worker
  }

  /**
   * Start Job
   *
   * @param {Object} data Job Data
   */
  start(data) {
    this.queue.jobs.push(this)
    if (this.immediate) {
      this.invoke(data)
    } else {
      this.enqueue(data)
    }
  }

  /**
   * Queue the next job run according to the wait duration
   *
   * @param {Object} data Job Data
   */
  enqueue(data) {
    this.timeout = setTimeout(this.invoke.bind(this), this.schedule.asMilliseconds(), data)
  }

  /**
   * Run the actual job
   *
   * @param {Object} data Job Data
   */
  async invoke(data) {
    try {
      if (this.worker) {
        this.finished = this.queue.threadPool.run(this.name, data)
      } else {
        this.finished = require(`../jobs/${this.name}`)(data)
      }
      await this.finished
    } catch (err) {
      WIKI.logger.warn(err)
    }
    if (this.repeat && this.queue.jobs.includes(this)) {
      this.enqueue(data)
    } else {
      this.stop().catch(() => {})
    }
  }

  /**
   * Stop any future job invocation from occuring
   */
  async stop() {
    clearTimeout(this.timeout)
    this.queue.jobs = this.queue.jobs.filter(x => x !== this)
    return this.finished
  }
}

module.exports = {
  jobs: [],
  threadPool: null,
  init() {
    return this
  },
  start() {
    const poolSize = _.get(WIKI, 'config.workers.threadPoolSize', 1)
    WIKI.logger.info(`(SCHEDULER) Starting thread pool with ${poolSize} worker(s)...`)
    this.threadPool = new ThreadPool(poolSize)
    this.threadPool.start()

    _.forOwn(WIKI.data.jobs, (queueParams, queueName) => {
      if (WIKI.config.offline && queueParams.offlineSkip) {
        WIKI.logger.warn(`Skipping job ${queueName} because offline mode is enabled. [SKIPPED]`)
        return
      }

      const schedule = (configHelper.isValidDurationString(queueParams.schedule)) ? queueParams.schedule : 'P1D'
      this.registerJob({
        name: _.kebabCase(queueName),
        immediate: _.get(queueParams, 'onInit', false),
        schedule: schedule,
        repeat: _.get(queueParams, 'repeat', false),
        worker: _.get(queueParams, 'worker', false)
      })
    })
  },
  registerJob(opts, data) {
    const job = new Job(opts, this)
    job.start(data)
    return job
  },
  async stop() {
    await Promise.all(this.jobs.map(job => job.stop()))
    if (this.threadPool) {
      await this.threadPool.stop()
    }
  }
}

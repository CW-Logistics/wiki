const path = require('path')
const { workerData, parentPort } = require('worker_threads')

let WIKI = {
  IS_DEBUG: process.env.NODE_ENV === 'development',
  ROOTPATH: process.cwd(),
  SERVERPATH: path.join(process.cwd(), 'server'),
  Error: require('../helpers/error'),
  configSvc: require('./config')
}
global.WIKI = WIKI

WIKI.configSvc.init()
WIKI.logger = require('./logger').init('JOB')

parentPort.postMessage({ ready: true })

parentPort.on('message', async ({ jobId, job, data }) => {
  try {
    await require(`../jobs/${job}`)(data)
    parentPort.postMessage({ jobId, ok: true })
  } catch (e) {
    parentPort.postMessage({ jobId, ok: false, error: e.message })
  }
})

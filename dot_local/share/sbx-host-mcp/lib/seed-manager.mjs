export function createSeedManager({ runHelper, formatError }) {
  const jobs = new Map();

  function status(job) {
    return {
      workItem: job.workItem,
      sandbox: `wi-${job.workItem}-vm`,
      seedStatus: job.status,
      startedAt: job.startedAt,
    };
  }

  function start(workItem, slug, repo) {
    const existing = jobs.get(workItem);
    if (existing?.status === "running") return status(existing);

    const job = {
      workItem,
      status: "running",
      startedAt: new Date().toISOString(),
      promise: undefined,
      error: undefined,
    };
    job.promise = runHelper(["seed", String(workItem), slug, repo])
      .then(() => {
        job.status = "succeeded";
      })
      .catch(error => {
        job.status = "failed";
        job.error = formatError(error);
      });
    jobs.set(workItem, job);
    return status(job);
  }

  async function wait(workItem, waitSeconds) {
    const job = jobs.get(workItem);
    if (!job) return { state: "absent" };
    if (job.status === "running" && waitSeconds > 0) {
      await Promise.race([
        job.promise,
        new Promise(resolve => setTimeout(resolve, waitSeconds * 1000)),
      ]);
    }
    if (job.status === "failed") {
      jobs.delete(workItem);
      return { state: "failed", error: job.error || "Sandbox seed failed" };
    }
    if (job.status === "running") {
      return { state: "running", status: status(job) };
    }
    jobs.delete(workItem);
    return { state: "completed" };
  }

  return { start, wait };
}

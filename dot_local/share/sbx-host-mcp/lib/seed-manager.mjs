export function createSeedManager({ taskManager }) {
  function status(job) {
    return {
      taskId: job.taskId,
      workItem: job.workItem,
      sandbox: job.sandbox,
      seedStatus: ["queued", "running"].includes(job.status)
        ? "running"
        : job.status,
      startedAt: job.startedAt || job.createdAt,
    };
  }

  async function start(workItem, slug, repo, reuseExistingBranch) {
    return status(
      await taskManager.startSeed(workItem, slug, repo, reuseExistingBranch),
    );
  }

  async function wait(workItem, waitSeconds) {
    let job = await taskManager.find(workItem, { kind: "seed" });
    if (!job) return { state: "absent" };
    if (["queued", "running"].includes(job.status) && waitSeconds > 0) {
      ({ task: job } = await taskManager.wait(job.taskId, waitSeconds * 1000));
    }
    if (["failed", "canceled"].includes(job.status)) {
      return {
        state: "failed",
        error:
          job.error ||
          await taskManager.logs(job.taskId, 16384) ||
          "Sandbox seed failed",
      };
    }
    if (["queued", "running"].includes(job.status)) {
      return { state: "running", status: status(job) };
    }
    return { state: "completed" };
  }

  return { start, wait };
}

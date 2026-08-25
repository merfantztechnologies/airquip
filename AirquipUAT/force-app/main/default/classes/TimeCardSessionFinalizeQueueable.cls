/**
 * Runs after FieldAX package Queueables that clone Travel/Job time cards,
 * so only one session Detail key remains per type.
 */
public without sharing class TimeCardSessionFinalizeQueueable implements Queueable {
    private final Id jobId;
    private final Id engineerId;
    private final Id assignmentId;

    public TimeCardSessionFinalizeQueueable(Id jobId, Id engineerId, Id assignmentId) {
        this.jobId = jobId;
        this.engineerId = engineerId;
        this.assignmentId = assignmentId;
    }

    public void execute(QueueableContext context) {
        JobAssignmentController.finalizeSessionTimeCards(jobId, engineerId, assignmentId);
    }
}
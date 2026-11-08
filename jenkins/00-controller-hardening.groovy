import hudson.model.Node
import hudson.security.csrf.DefaultCrumbIssuer
import jenkins.model.Jenkins
import java.util.logging.Logger

def controller = Jenkins.get()
controller.setNumExecutors(0)
controller.setMode(Node.Mode.EXCLUSIVE)
controller.setSlaveAgentPort(-1)
if (controller.getCrumbIssuer() == null) {
    controller.setCrumbIssuer(new DefaultCrumbIssuer(false))
}
controller.save()
Logger.getLogger("controller-hardening").info(
    "Controller hardening applied: executors=0, agent TCP disabled, CSRF enabled"
)

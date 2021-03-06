local config = import 'config.libsonnet';
local k = import 'ksonnet-util/kausal.libsonnet';

k + config {
  local configMap = $.core.v1.configMap,
  local container = $.core.v1.container,
  local daemonSet = $.apps.v1.daemonSet,
  local deployment = $.apps.v1.deployment,
  local policyRule = $.rbac.v1beta1.policyRule,

  agent_rbac:
    $.util.rbac($._config.agent_cluster_role_name, [
      policyRule.new() +
      policyRule.withApiGroups(['']) +
      policyRule.withResources(['nodes', 'nodes/proxy', 'services', 'endpoints', 'pods']) +
      policyRule.withVerbs(['get', 'list', 'watch']),

      policyRule.new() +
      policyRule.withNonResourceUrls('/metrics') +
      policyRule.withVerbs(['get']),
    ]),

  agent_config_map:
    configMap.new($._config.agent_configmap_name) +
    configMap.withData({
      'agent.yml': $.util.manifestYaml($._config.agent_config),
    }),

  agent_args:: {
    'config.file': '/etc/agent/agent.yml',
    'prometheus.wal-directory': '/tmp/agent/data',
  },

  agent_container::
    container.new('agent', $._images.agent) +
    container.withPorts($.core.v1.containerPort.new('http-metrics', 80)) +
    container.withArgsMixin($.util.mapToFlags($.agent_args)) +
    container.withEnv([
      container.envType.fromFieldPath('HOSTNAME', 'spec.nodeName'),
    ]) +
    container.mixin.securityContext.withPrivileged(true) +
    container.mixin.securityContext.withRunAsUser(0),

  config_hash_mixin:: {
    local hash(config) = { config_hash: std.md5(std.toString(config)) },
    daemonSet:
      if $._config.agent_config_hash_annotation then
        daemonSet.mixin.spec.template.metadata.withAnnotationsMixin(hash($._config.agent_config))
      else {},
    deployment:
      if $._config.agent_config_hash_annotation then
        deployment.mixin.spec.template.metadata.withAnnotationsMixin(hash($._config.deployment_agent_config))
      else {},
  },

  // TODO(rfratto): persistent storage for the WAL here is missing. hostVolume?
  agent_daemonset:
    daemonSet.new($._config.agent_pod_name, [$.agent_container]) +
    daemonSet.mixin.spec.template.spec.withServiceAccount($._config.agent_cluster_role_name) +
    self.config_hash_mixin.daemonSet +
    $.util.configVolumeMount($._config.agent_configmap_name, '/etc/agent'),

  agent_deployment_config_map:
    if $._config.agent_host_filter then
      configMap.new($._config.agent_deployment_configmap_name) +
      configMap.withData({
        'agent.yml': $.util.manifestYaml($._config.deployment_agent_config),
      })
    else {},

  agent_deployment:
    if $._config.agent_host_filter then
      deployment.new($._config.agent_deployment_pod_name, 1, [$.agent_container]) +
      deployment.mixin.spec.template.spec.withServiceAccount($._config.agent_cluster_role_name) +
      deployment.mixin.spec.withReplicas(1) +
      self.config_hash_mixin.deployment +
      $.util.configVolumeMount($._config.agent_deployment_configmap_name, '/etc/agent')
    else {},
}

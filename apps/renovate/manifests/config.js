module.exports = {
  hostRules: [
    {
      matchHost: "docker.io",
      hostType: "docker",
      username: process.env.RENOVATE_DOCKER_USERNAME,
      password: process.env.RENOVATE_DOCKER_PASSWORD,
    },
    {
      matchHost: "hub.docker.com",
      hostType: "docker",
      username: process.env.RENOVATE_DOCKER_USERNAME,
      password: process.env.RENOVATE_DOCKER_PASSWORD,
    },
  ],
};

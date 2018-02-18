pipeline {
  agent none

  environment {
    GCLOUD_AUTH_BASE64 = credentials('GCLOUD_AUTH_BASE64')
  }

  stages {
    stage('Test') {
      agent {
        docker { image 'docker.io/controlplane/gcloud-sdk:latest' }
      }

      environment {
        DEFAULT_PROJECT = 'controlplane-dev-2'
        DEFAULT_ZONE = 'europe-west2-c'
        PERSIST_CLUSTER = '1'
      }

      steps {
        ansiColor('xterm') {
          sh 'HOME=$(pwd); ./test/test-remote.sh; '
        }
      }
    }
  }
}

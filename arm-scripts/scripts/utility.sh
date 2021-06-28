function install_jdk() {
    export JAVA_HOME=/usr/lib/jvm/msopenjdk-11-amd64
    if [ ! -d "${JAVA_HOME}" ]; then
        # Install Microsoft OpenJDK
        wget https://packages.microsoft.com/config/ubuntu/18.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
        sudo dpkg -i packages-microsoft-prod.deb
        sudo apt -q update
        sudo apt -y -q install msopenjdk-11

        echo "java version"
        java -version
        if [ $? -ne 1 ]; then
            exit 1
        fi
    fi
}

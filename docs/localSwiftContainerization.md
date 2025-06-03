# Develop using a local copy of Containerization

This page describes how to build and run container using a local copy of [`Containerization`](https://github.com/apple-uat/containerization).

## Use the local copy of containerization

1. Clone the [Containerization](https://github.com/apple-uat/containerization) repository such that it sits next to your clone of the `container` repository.

2. In your development shell, go to the `container` project directory.
    
    ```
    cd container
    ```

3. If the application services are already running, stop them. 

    ```
    bin/container system stop
    ```

4. Configure the environment variable `CONTAINERIZATION_PATH` to refer to your Containerization project, and update your `Package.resolved` file.
    
    ```
    export CONTAINERIZATION_PATH=../containerization
    swift package update containerization
    ```

5. Build the init filesystem for your local copy of containerization.

    ```
    (cd ../swiftcontainerization && make clean all)
    ```

6. Build `container`.

    ```
    make clean all
    ```

7. Start the application services.

    ```
    bin/container system start
    ```

## Revert to the versioned Containerization package

1. Unset your `CONTAINERIZATION_PATH` environment variable, and update `Package.resolved`.
    
    ```
    unset CONTAINERIZATION_PATH
    swift package update containerization
    ```

2. Rebuild `container`.

    ```
    make clean all
    ```

3. Restart application services.

    ```
    bin/container system restart
    ```

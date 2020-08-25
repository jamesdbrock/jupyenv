{ pkgs }:

let
  jupyter = pkgs.python3Packages.jupyterlab;

  # From a jupyter labextension source directory, run the `npm run build`
  # step. Produces an output which can be passed to
  # `jupyter labextension install`.
  # https://jupyterlab.readthedocs.io/en/stable/user/extensions.html#jupyterlab-build-process
  mkBuildExtension = srcPath: pkgs.stdenv.mkDerivation {
    name = "labextension-source";
    src = srcPath;
    buildInputs = with pkgs; [ nodejs nodePackages.typescript ];
    buildPhase = ''
      export HOME=$TMP
      npm install
      npm run build
      rm --recursive --force node_modules
      '';
    installPhase = ''
      mkdir --parents $out/
      cp --recursive * $out/
      '';
  };

in

{
  generateDirectory = pkgs.writeScriptBin "generate-directory" ''
    if [ $# -eq 0 ]
      then
        echo "Usage: generate-directory [EXTENSION]"
      else
        DIRECTORY="./jupyterlab"
        echo "Generating directory '$DIRECTORY' with extensions:"

        # we need to copy yarn.lock manually to the staging directory to get
        # write access this seems to be a bug in jupyterlab that doesn't
        # consider that it comes from a folder without read access only as in
        # Nix
        mkdir -p "$DIRECTORY"/staging
        cp ${jupyter}/lib/python3.7/site-packages/jupyterlab/staging/yarn.lock "$DIRECTORY"/staging
        chmod +w "$DIRECTORY"/staging/yarn.lock

        for EXT in "$@"; do echo "- $EXT"; done
        ${jupyter}/bin/jupyter-labextension install "$@" --app-dir="$DIRECTORY" --generate-config
        chmod -R +w "$DIRECTORY"/*
    fi
  '';

  generateLockFile = pkgs.writeScriptBin "generate-lockfile" ''
    if [ $# -eq 0 ]
      then
        echo "Usage: generate-lockfile [EXTENSION]"
      else
        DIRECTORY=$(mktemp -d)
        WORKDIR="lockfiles"

        mkdir -p "$DIRECTORY"/staging
        cp ${jupyter}/lib/python3.7/site-packages/jupyterlab/staging/yarn.lock "$DIRECTORY"/staging
        chmod +w "$DIRECTORY"/staging/yarn.lock

        echo "Generating lockfiles for extensions:"

        for EXT in "$@"; do echo "- $EXT"; done
        ${jupyter}/bin/jupyter-labextension install "$@" --app-dir="$DIRECTORY"

        mkdir -p $WORKDIR
        mv "$DIRECTORY/staging/yarn.lock" $WORKDIR
        mv "$DIRECTORY/staging/package.json" $WORKDIR
    fi
  '';

  mkDirectoryFromLockFile = { yarnlock, packagefile, extensions ? [], sha256 }:
    let
      # Should this exist?
      copyExtension = { name, version }: ''
        cp -r $PREFIX/${name}/* package
        tar -cvzf $out/extensions/${name}-${version}.tgz package
        rm -rf package/*

      '';
      copyExtensions = pkgs.lib.concatMapStrings copyExtension extensions;
    in
    pkgs.stdenv.mkDerivation {
      name = "jupyterlab-from-yarnlock";
      phases = [ "installPhase" ];
      nativeBuildInputs = [ pkgs.breakpointHook ];
      buildInputs = with pkgs; [
        jupyter
        nodejs
        nodePackages.webpack
        nodePackages.webpack-cli
      ];
      installPhase = ''
        # This is needed so Jupyter looks for configuration at accessible
        # folders.
        export HOME=$TMP

        # The local folder where the build and installation will be performed.
        export FOLDER=folder

        # Copy the default JupyterLab folder to the build location and give
        # write permissions to it.
        mkdir -p $FOLDER
        cp -R ${jupyter}/lib/python3.7/site-packages/jupyterlab/* $FOLDER
        chmod -R +rw $FOLDER

        # Overwrite yarn.lock and package.json with the ones that we want. Make
        # them writable, since this is required by Jupyter.
        cp ${yarnlock} $FOLDER/staging/yarn.lock
        cp ${packagefile} $FOLDER/staging/package.json
        chmod +rw $FOLDER/staging/*

        # Rebuild with jlpm. This will install the needed dependencies and
        # rebuild the folder.
        cd $FOLDER/staging
        jlpm install
        jlpm build
        cd ../..

        # Move the necessary Jupyter folders to the Nix store.
        mkdir -p $out
        chmod -R +rw $FOLDER
        cp -r folder/{schemas,static,themes,imports.css} $out

        # Disable build check, since the folder is read-only and no further
        # modifications are possible. This also removes the "Build Recommended"
        # warning at each startup.
        mkdir -p $out/settings
        echo '{"buildCheck": false}' > $out/settings/page_config.json
      '';

      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = sha256;
    };

#  mkDirectoryWith = { extensions }:
#    # Creates a JUPYTERLAB_DIR with the given extensions.
#    # This operation is impure, so it requires `--option sandbox false`.
#    #
#    # The `extensions` list elements can be “the name of a valid JupyterLab
#    # extension npm package on npm,” or “can be a local directory containing
#    # the extension, a gzipped tarball, or a URL to a gzipped tarball.”
#    # See
#    # https://jupyterlab.readthedocs.io/en/stable/user/extensions.html#installing-extensions
#    let extStr = pkgs.lib.concatStringsSep " " extensions; in
#    pkgs.stdenv.mkDerivation {
#      name = "jupyterlab-extended";
#      phases = "installPhase";
#      buildInputs = [ jupyter pkgs.nodejs ];
#      installPhase = ''
#        export HOME=$TMP
#
#        mkdir -p appdir/staging
#        cp ${jupyter}/lib/python3.7/site-packages/jupyterlab/staging/yarn.lock appdir/staging
#        chmod +w appdir/staging/yarn.lock
#
#        jupyter labextension install ${extStr} --app-dir=appdir --debug
#        rm -rf appdir/staging/node_modules
#        mkdir -p $out
#        cp -r appdir/* $out
#      '';
#    };

  # Call `jupyter labextension install` to build JupyterLab together
  # with its extensions and create a JUPYTERLAB_DIR.
  # This operation is impure.
  #
  # From
  # https://jupyterlab.readthedocs.io/en/stable/user/extensions.html#installing-extensions
  # The `extensions` list elements can be “the name of a valid JupyterLab
  # extension npm package on npm,” or “can be a local directory containing
  # the extension, a gzipped tarball, or a URL to a gzipped tarball.”
  #
  # Arguments
  # • extensions: a list of strings which can be any of
  #    - extension package name on http://npmjs.com
  #    - gzipped tarball
  #    - URL to gzipped tarball
  # • extensionsLocal: a list of local directory paths containing extensions
  mkDirectoryWith = { extensions ? [], extensionsLocal ? [] }:
    let
      strNPM = pkgs.lib.concatStringsSep " " extensions;
      # jupyterlab doesn't `yarn run build` on local extensions. Why? I think
      # because of this line, which says that if the os path doesn't exist, then
      # don't build.
      # https://github.com/jupyterlab/jupyterlab/blob/f06c41601b45724ef40963217c575546b6f8bac2/jupyterlab/commands.py#L214
      strLocal = pkgs.lib.concatStringsSep " " (map mkBuildExtension extensionsLocal);
    in
    pkgs.stdenv.mkDerivation {
      name = "jupyterlab-extended";
      phases = "buildPhase installPhase";
      buildInputs = [ jupyter pkgs.nodejs ];
      outputs = [ "out" "outExtension" ];
      buildPhase = ''
        # This is needed so Jupyter looks for configuration at accessible
        # folders.
        export HOME=$TMPDIR

        # Copy all of the local extension directories into a
        # mutable outExtension directory, so that
        # JupyterLab's yarn builder can create node_modules
        # subdirectories.
        mkdir --parents $outExtension
        cp --target-directory=$outExtension --recursive ${strLocal}
        chmod --recursive +w $outExtension

        # Workaround for read-only yarn.lock
        # https://github.com/jupyterlab/jupyterlab/issues/7525
        # https://github.com/tweag/jupyterWith/issues/31
        mkdir -p appdir/staging
        cp ${jupyter}/lib/python3.[7-9]/site-packages/jupyterlab/staging/yarn.lock appdir/staging
        chmod +w appdir/staging/yarn.lock
        jupyter labextension install --app-dir=appdir --debug --dev-build=False ${strNPM} $outExtension/*
        chmod -w appdir/staging/yarn.lock

        # Disable build check, since the folder is read-only and no further
        # modifications are possible. This also removes the "Build Recommended"
        # warning at each startup.
        # https://jupyterlab.readthedocs.io/en/stable/user/extensions.html#settings
        # https://jupyterlab.readthedocs.io/en/stable/user/extensions.html#disabling-rebuild-checks
        mkdir -p appdir/settings
        echo '{"buildCheck": false}' > appdir/settings/page_config.json

        rm --recursive --force appdir/staging/node_modules
      '';
      installPhase = ''
        mkdir -p $out
        cp -r appdir/* $out
      '';
    };

}

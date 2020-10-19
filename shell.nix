{ overlays ? []
, config ? {}
, pkgs ? import ./nix { inherit config overlays; }
}:

let
  jupyter = import ./default.nix { inherit config overlays pkgs; };

  iPython = jupyter.kernels.iPythonWith {
    name = "python";
    packages = p: with p; [ numpy ];
  };

  # https://github.com/yuvipanda/nbresuse
  # Needed for jupyterlab-system-monitor
  nbresuse = pkgs.python3Packages.buildPythonPackage rec {
    pname = "nbresuse";
    version = "0.3.6";
    src = pkgs.python3Packages.fetchPypi {
      inherit pname version;
      sha256 = "13p9chk341iy78zwa2vmrnqkysi70wpxlk5kmrq99wcgn389v8av";
    };
    propagatedBuildInputs = with pkgs.python3Packages; [ notebook psutil mock ];
  };

  jupyterEnvironment =
    jupyter.jupyterlabWith {
      kernels = [ iPython ];
      directory = jupyter.mkDirectoryWith {
        extensions = [
          "jupyterlab-topbar-extension@0.5.0"
          "jupyterlab-system-monitor@0.6.0"
        ];
      };
      extraPackages = p: [ nbresuse pkgs.python3Packages.psutil ];
      extraInputsFrom = _: [ nbresuse ];
      extraJupyterPath = _: "${nbresuse}/lib/python3.7/site-packages:${pkgs.python3Packages.psutil}/lib/python3.7/site-packages";
    };
in
  jupyterEnvironment.env

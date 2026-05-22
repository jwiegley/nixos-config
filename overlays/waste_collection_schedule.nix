{
  lib,
  buildHomeAssistantComponent,
  fetchFromGitHub,
  beautifulsoup4,
  icalendar,
  icalevents,
  lxml,
  pycryptodome,
  pypdf,
  pdfminer-six,
  curl_cffi,
}:

buildHomeAssistantComponent rec {
  owner = "mampfes";
  domain = "waste_collection_schedule";
  version = "2.24.0";

  src = fetchFromGitHub {
    inherit owner;
    repo = "hacs_waste_collection_schedule";
    tag = "v${version}";
    hash = "sha256-fCtgEfaoI9IVEpe3YMFb8IkzNmGalueZaGv9JpS35Ok=";
  };

  dependencies = [
    beautifulsoup4
    icalendar
    icalevents
    lxml
    pycryptodome
    pypdf
    pdfminer-six
    curl_cffi
  ];

  meta = {
    changelog = "https://github.com/mampfes/hacs_waste_collection_schedule/releases/tag/${version}";
    description = "Home Assistant integration framework for (garbage collection) schedules";
    homepage = "https://github.com/mampfes/hacs_waste_collection_schedule";
    maintainers = with lib.maintainers; [ jamiemagee ];
    license = lib.licenses.mit;
  };
}

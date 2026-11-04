DMetFinder agent CLI 1.0.4
==========================

This folder runs DMetFinder's A/B differential-ion screening from the
command line, without starting the Shiny app. It produces the same
numbers as the app -- verified cell by cell over 40.9 million cells.

QUICK START (3 steps)
---------------------

1. Install R 4.3 or newer
       https://cloud.r-project.org/

2. Open cmd.exe in this folder, then run
       Rscript setup.R
   It installs five packages and ends with a self-check. You want to
   see "RESULT: all required packages are present."

3. Run the demo to confirm everything works
       cli\run-dmf.bat diff --a demo_data\groupA.xlsx --b demo_data\groupB.xlsx --out out\run1

   This takes about a minute on the demo data and writes roughly
   230 MB. When it finishes you should have 18 CSV files in
   out\run1\tables\ plus out\run1\run.json.


WHAT YOU GET
------------

   out\run1\tables\*.csv   the 18 result tables, one CSV per sheet
   out\run1\schema.csv     what every column is, and where it came from
   out\run1\run.json       parameters, sha256 of every input and output


READ NEXT
---------

   docs\agent\QUICKSTART.md      full guide, troubleshooting (Chinese)
   docs\agent\CLI_CONTRACT.md    JSON output format and exit codes
   MANIFEST.txt                  sha256 of every file in this folder
   renv.lock                     exact package versions we tested with


IF SOMETHING FAILS
------------------

   Rscript setup.R --check-only

prints what is missing without changing anything. For anything else,
see the "Troubleshooting" section of docs\agent\QUICKSTART.md.

Note: this package contains only the command-line path. The Peak
Quality module is still under development and is deliberately not
included -- do not expect it to appear here.

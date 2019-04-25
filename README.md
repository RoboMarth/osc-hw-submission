# OSC Homework Submission

An OnDemand app that wraps the command line script `hw_dir_setup` for secure(?)
homework submission on the Ohio Supercomputer Center.

## Installation (Developer Preview)

### Step 1

Through an OSC login node, create the directory `~/ondemand/dev` and then clone
this repository into that directory:

```
mkdir -p ~/ondemand/dev && cd ~/ondemand/dev
git clone https://github.com/RoboMarth/osc-hw-submission.git 
```

Note: this step may change with OnDemand 1.4, see
[here](https://osc.github.io/ood-documentation/master/app-development/enabling-development-mode.html)
for more details.

### Step 2

Login into OSC OnDemand. There should be an option `Develop` in the top navbar
that appeared because of the creation of the folder in Step 1. 

Select `Develop > My Sandbox Apps (Development) > Launch Homework
Submission` to preview the app as an instructor.

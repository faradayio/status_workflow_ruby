# StatusWorkflow

Basic state machine using Redis for locking.

```
require 'redis'
StatusWorkflow.redis = Redis.new
```

Expects but does not require ActiveRecord (you just have to respond to `#reload`, `#id`, and `#update_columns`)

```
class Pet < ActiveRecord::Base
  before_create do
    self.status ||= 'sleep'
  end
  include StatusWorkflow
  status_workflow(
    sleep: [:fed],
    fed: [:sleep, :run],
    run: [:sleep],
  )
end
```

where

```
    sleep: [:fed],
    fed: [:sleep, :run],
    run: [:sleep],
```

means:

* from sleep, i can go to fed
* from fed, i can go to sleep or run
* from run, i can go to sleep

## Sponsor

<p><a href="https://www.faraday.io"><img src="https://s3.amazonaws.com/faraday-assets/files/img/logo.svg" alt="Faraday logo"/></a></p>

We use [`status_workflow`](https://github.com/faradayio/status_workflow_ruby) for [B2C customer lifecycle optimization at Faraday](https://www.faraday.io).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/status_workflow. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the StatusWorkflow project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/status_workflow/blob/master/CODE_OF_CONDUCT.md).

## Copyright

Copyright 2018 Faraday

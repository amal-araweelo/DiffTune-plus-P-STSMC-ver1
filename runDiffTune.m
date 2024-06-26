% Use this script to 
% run the simulation with DiffTune

% Constant drive train parameters
% N: Gearing ratio
% J_m: Motor inertia
% J_l: Load inertia
% K_S: Shaft stifness
% D_S: Shaft damping coefficinet
% T_Cm: Motor Coulomb friction
% T_Sm: Motor static friction coefficient
% omega_s: Motor Stribeck velocity
% beta_m: Motor viscous friction coefficient

% Disturbances
% d_e: Input torque ripples and harmonics
% T_Fm: Motor friction
% T_Fl: Load friction
% T_l: Load torque

% States include
% omega_m: Motor angular velocity
% omega_l: Load angular velocity
% theta_m: motor angular position
% theta_l: load angular position
% X = [omega_m; omega_l; theta_m; theta_l]
% Xref = theta_r(k)

% Control includes
% theta_r: Load postition reference
% omega_r: Motor velocity reference
% u: Torque command

close all;
clear all;
clc;

addpath('mex\');
addpath('Common\');
addpath('Results\');
import casadi.*

%% define the dimensions
dim_state = 4; % dimension of system state
dim_control = 1;  % dimension of control inputs
dim_controllerParameters = 3;  % dimension of controller parameters

%% Video simulation
param1.generateVideo = true;
if param1.generateVideo
    video_obj = VideoWriter('Results\DriveTrain.mp4','MPEG-4');
    video_obj.FrameRate = 15;
    open(video_obj);
end

%% Define simulation parameters (e.g., sample time dt, duration, etc)
dt = 0.001;     % 1 kHz
time = 0:dt:10; % 10 s

%% constant parameters
% Motor mechanical parameters
N = 1;                  % -- Gear ratio
J_m = 2.81e-4 + 5.5e-4; % kgm^2 -- Moment of inertia     (8.31e-4 kg m^2)
% J_l = 1;                % kgm^2 -- Moment of inertia
J_l = 0.000831;

% Taken from Table 4.3: Summary of calculated friction and shaft parameters
% (page 40, Dimitrios Papageorgiou phd thesis)
K_S = 32.94;        % N m rad^(-1)
D_S = 0.0548;       % N m s rad^(-1)
T_Cm = 0.0223;      % N m
T_Cl = 0.0232;      % N m
beta_m = 0.0016;    % N m s rad^(-1)
beta_l = 0.0016;    % N m s rad^(-1)

param = [N J_m J_l K_S D_S T_Cm T_Cl beta_m beta_l];

%% Initialize controller gains (must be a vector of size dim_controllerParameters x 1)
% STSMC (in nonlinear controller for omega_m)
k1 = 1;
k2 = 1;
k_pos = 1;      % ignored when hand-tuning STSMC
k_vec = [k1; k2; k_pos];

%% Define desired trajectory if necessary
freq = 1;   % 1 rad/s
theta_r = sin(freq * time);   % theta_r is a sine wave with frequency 1 rad/s
theta_r_dot = freq * cos(freq * time);
theta_r_2dot = - freq^2 * sin(freq * time);

%% Initialize variables for DiffTune iterations
learningRate = 1; 
lambda = 1;
alpha_star = 1;
maxIterations = 50;
itr = 0;

loss_hist = [];  % storage of the loss value in each iteration
rmse_hist = []; % If we want video
param_hist = []; % storage of the parameter value in each iteration
gradientUpdate = zeros(dim_controllerParameters,1); % define the parameter update at each iteration

%% DiffTune iterations
while (1)
    itr = itr + 1;
    fprintf('------------------------\n');
    fprintf('itr = %d \n\n', itr);

    % fprintf('before: \n');
    % fprintf('k1 = %.3f \n', k_vec(1));
    % fprintf('k2 = %.3f \n', k_vec(2));
    % fprintf('k_pos = %.3f \n', k_vec(3));

    % if itr == 1
    %     fprintf('k_vec = \n');
    %     disp(k_vec);
    % end

    % Initialize state
    X_storage = zeros(dim_state,1);
    
    % Initialize sensitivity
    dx_dtheta = zeros(dim_state, dim_controllerParameters);
    du_dtheta = zeros(dim_control, dim_controllerParameters);

    % Initialize loss and gradient of loss
    loss = 0;
    theta_gradient = zeros(1, dim_controllerParameters);

    % Storage for sensitivity norms
    dx_dtheta_norm_sum = 0;
    du_dtheta_norm_sum = 0;

    % global v;
    v = 0;

    for k = 1 : length(time) - 1
       
        % Load current state and current reference
        X = X_storage(:,end);   % X = [omega_m; omega_l; theta_m; theta_l]
        Xref = theta_r(k);
 
        % Compute the control action
        [u, v] = controller(X, Xref, k_vec, theta_r_dot(k), theta_r_2dot(k), param, dt, v); 

        % Compute the sensitivity 
        [dx_dtheta, du_dtheta] = sensitivityComputation(dx_dtheta, X, Xref, theta_r_dot(k), theta_r_2dot(k), u, param, k_vec, dt, v);

        % Loss w/respect to state X
        dloss_dx = 2 * [0 0 0 X(4)-Xref];

        % Loss w/respect to control input u
        dloss_du = 0;

        % Accumulate the loss (mean-squared-error (MSE))
        loss = loss + norm(Xref-X(4))^2;      % (Xref-X(4))^2 = (X(4)-Xref)^2

        % Accumulating the gradient of loss w/ respect to controller parameters
        theta_gradient = theta_gradient + dloss_dx * dx_dtheta + dloss_du * du_dtheta;

        % Accumulate the norms for alpha_star calculation
        dx_dtheta_norm_sum = dx_dtheta_norm_sum + norm(dx_dtheta * theta_gradient', 2)^2;
        du_dtheta_norm_sum = du_dtheta_norm_sum + norm(du_dtheta * theta_gradient', 2)^2;

        % Integrate the ode dynamics
        [~,sold] = ode45(@(t,X)dynamics(t, X, u, param'),[time(k) time(k+1)], X);
        X_storage = [X_storage sold(end,:)'];   % store the new state
        
    end

    % Compute the RMSE (root-mean-square error)
    RMSE = sqrt(1 / (length(time)-1) * loss);

    % Store loss and RMSE
    loss_hist = [loss_hist loss];
    rmse_hist = [rmse_hist RMSE];

    % Numerator for alpha_star
    num = 0.5 * (theta_gradient)*theta_gradient';

    % Denominator for alpha star
    den = dx_dtheta_norm_sum + lambda * du_dtheta_norm_sum;

    % Alpha star
    alpha_star = (num/den);

    % Learning rate update
    learningRate = learningRate + alpha_star; 

    % Update the gradient
    gradientUpdate = - learningRate * theta_gradient;

    % Sanity check
    if isnan(gradientUpdate)
       fprintf('gradient is NAN. Quit.\n');
       break;
    end

    % Gradient descent
    k_vec = k_vec + gradientUpdate';    % ' used for transposing matrix or vector

    fprintf('after: \n');
    fprintf('k1 = %.4f, grad = %.4f \n', k_vec(1), theta_gradient(1));  % OBS gradienten der printes er gradienten udregnet for den tidligere k_vec værdi
    fprintf('k2 = %.4f, grad = %.4f \n', k_vec(2), theta_gradient(2));
    fprintf('k_pos = %.4f, grad = %.4f \n', k_vec(3), theta_gradient(3));
    fprintf('loss = %.4f \n', loss);

    % projection of all parameters to be > 0.5
    % if k_vec(1) < 0.5

    if any(k_vec < 0.5)
        neg_indicator = (k_vec < 0.5);  % produces 3x1 array with 1 if smaller and 0 if not
        pos_indicator = ~neg_indicator;
        k_default = 0.5*ones(dim_controllerParameters,1);
        k_vec = neg_indicator.*k_default + pos_indicator.*k_vec;
    end

    % store the parameters
    param_hist = [param_hist k_vec];

    % Plotting
    set(gcf, 'Position', [100, 100, 1000, 600]);
    set(gcf,'color','w');

    % Position (theta_l) tracking
    subplot(1,3,[1 2]);
    plot(time,X_storage(4,:),'LineWidth',1.5);
    hold on;
    plot(time,theta_r,'--','LineWidth',1.5);
    xlabel('time (s)');
    ylabel('position (rad)');
    grid on;
    lgd = legend('\theta_l', '\theta_r','Location','southeast');
    set(lgd, 'FontSize', 10)
    % h_lgd = legend;
    % set(h_lgd,'Position',[0.3811 0.8099 0.1097 0.0846],'FontSize',10);
    set(gca,'FontSize',10);

    text(0.15,-0.67,['learningRate = ' num2str(learningRate)]);
    text(0.15,-0.74,['k1 = ' sprintf('%.4f', k_vec(1)) ', grad = ' sprintf('%.4f', theta_gradient(1))]);
    text(0.15,-0.81,['k2 = ' sprintf('%.4f', k_vec(2)) ', grad = ' sprintf('%.4f', theta_gradient(2))]);
    text(0.15,-0.88,['k\_pos = ' sprintf('%.4f', k_vec(3)) ', grad = ' sprintf('%.4f', theta_gradient(3))]);
    text(0.15,-0.95,['loss = ' sprintf('%.4f', loss)]);

    % RMSE
    subplot(1,3,3);
    plot(rmse_hist,'LineWidth',1.5);
    hold on;
    grid on;
    stem(length(rmse_hist),rmse_hist(end),'Color',[0 0.4470 0.7410]);

    xlim([0 maxIterations]);
    ylim([0 rmse_hist(1)*1.1]);
    text(25,0.025,['iteration = ' num2str(length(rmse_hist))],'FontSize',10);
    xlabel('iterations');
    ylabel('RMSE (rad)');
    set(gca,'FontSize',10);
    plotedit(gca,'on');
    plotedit(gca,'off');

    drawnow;

    % Visualization for movie
    if param1.generateVideo
        frame = getframe(gcf);
        writeVideo(video_obj,frame);
        clf
    end

    % Terminate if the total number of iterations is more than maxIterations
    if itr >= maxIterations
       break;
    end
end

if param1.generateVideo
    close(video_obj);
end

%% Plot trajectory
h = figure(2);

plot(time, X_storage(4,:),'LineWidth',1.5);
hold on;
plot(time, theta_r,'--','LineWidth',1.5);
hold off;

grid on;
lgd = legend('\theta_l', '\theta_r', 'Location', 'southeast');
set(lgd, 'FontSize', 10);
xlabel('time (s)', 'FontSize', 10);
ylabel('position (rad)', 'FontSize', 10);
set(gca, 'FontSize', 10);

text(0.5,-0.55,['k1 = ' sprintf('%.4f', k_vec(1))],'FontSize',10);
text(0.5,-0.65,['k2 = ' sprintf('%.4f', k_vec(2))],'FontSize',10);
text(0.5,-0.75,['k\_pos = ' sprintf('%.4f', k_vec(3))],'FontSize',10);
text(0.5,-0.85,['rmse = ' sprintf('%.4f', rmse_hist(end))],'FontSize',10);

saveas(h, 'Results\sine resp.png');

% h = figure(3);
% plot(time, X_storage(1,:),'DisplayName','\omega_m','LineWidth',1.5);
% hold on;
% plot(time, X_storage(2,:),'DisplayName','\omega_l','LineWidth',1.5);
% legend();
% ylabel('\omega [rad/s]');
% saveas(h, 'Results\omega_m og omega_l.png');

